"""
Flower FL Dashboard — Real-time federated learning monitoring for OpenNebula.

Collects cluster state from OpenNebula CLI, Docker containers on each VM,
and SuperLink training logs. Serves a single-page dashboard at port 8080.
"""

import asyncio
import json
import os
import re
import signal
import subprocess
import tempfile
import threading
import time
import tomllib
from collections import deque
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import HTMLResponse, FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field as PydField

app = FastAPI(title="Flower FL Dashboard")
app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SSH_USER = os.environ.get("FL_SSH_USER", "root")
SSH_OPTS = "-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
SUPERLINK_CONTAINER = "flower-superlink"
SUPERNODE_CONTAINER = "flower-supernode"

DEMO_BASE = Path(__file__).parent.parent / "demo"
FLWR_BIN = DEMO_BASE / ".venv" / "bin" / "flwr"
SUPERNODE_IMAGE_TAG = "1.25.0"


# ---------------------------------------------------------------------------
# Training control state
# ---------------------------------------------------------------------------
@dataclass
class ActiveTraining:
    process: subprocess.Popen
    framework: str
    config: dict
    started_at: float
    output_lines: deque  # maxlen=500


_active_training: Optional[ActiveTraining] = None
_last_completed: Optional[dict] = None
_training_reset: bool = False
_monitoring_run: bool = False  # True after flwr run submits job; training runs on SuperLink
_superlink_ip_cache: str = ""


class TrainingRequest(BaseModel):
    framework: str = PydField(..., pattern=r"^(pytorch|tensorflow|sklearn)$")
    num_rounds: int = PydField(3, ge=1, le=100)
    strategy: str = PydField("FedAvg")
    local_epochs: int = PydField(1, ge=1, le=50)
    batch_size: int = PydField(32, ge=1, le=512)
    min_fit_clients: int = PydField(2, ge=1)
    min_available_clients: int = PydField(2, ge=1)
    extra_config: dict = PydField(default_factory=dict)


def _reader_thread(proc, lines_deque):
    """Read subprocess stdout line by line into a deque."""
    for line in iter(proc.stdout.readline, ''):
        lines_deque.append(line.rstrip('\n'))
    proc.stdout.close()


# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------
@dataclass
class NodeInfo:
    vm_id: int
    name: str
    role: str  # "superlink" or "supernode"
    ip: str
    status: str  # "running", "stopped", "error"
    cpu: int = 0
    memory_mb: int = 0
    container_status: str = "unknown"
    container_uptime: str = ""
    flower_version: str = ""
    superlink_address: str = ""
    framework: str = ""


@dataclass
class RoundMetrics:
    round_num: int
    loss: Optional[float] = None
    accuracy: Optional[float] = None
    fit_clients: int = 0
    fit_failures: int = 0
    eval_clients: int = 0
    eval_failures: int = 0


@dataclass
class RunInfo:
    run_id: str = ""
    status: str = "idle"  # "idle", "running", "completed", "failed"
    num_rounds_configured: int = 0
    num_rounds_completed: int = 0
    total_duration_s: float = 0
    rounds: list = field(default_factory=list)
    model_info: dict = field(default_factory=dict)


@dataclass
class ClusterState:
    timestamp: str = ""
    nodes: list = field(default_factory=list)
    current_run: dict = field(default_factory=dict)
    connected_supernodes: int = 0
    superlink_ip: str = ""


# ---------------------------------------------------------------------------
# Shell helpers
# ---------------------------------------------------------------------------
def _run(cmd: str, timeout: int = 10) -> tuple[int, str]:
    """Run a shell command, return (returncode, stdout+stderr)."""
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout,
        )
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 1, "timeout"
    except Exception as e:
        return 1, str(e)


def _ssh(ip: str, cmd: str, timeout: int = 8) -> tuple[int, str]:
    """SSH to a VM and run a command."""
    return _run(f"ssh {SSH_OPTS} {SSH_USER}@{ip} {repr(cmd)}", timeout=timeout)


# ---------------------------------------------------------------------------
# SuperNode framework switching
# ---------------------------------------------------------------------------
def _switch_supernode_framework(
    nodes: list[NodeInfo], framework: str, superlink_ip: str,
) -> list[dict]:
    """Stop/rm/run SuperNode containers with the requested framework image.

    Only switches nodes whose current image doesn't already match.
    Returns a per-node list of {node, ip, switched, success, message}.
    """
    image = f"flower-supernode-{framework}:{SUPERNODE_IMAGE_TAG}"
    results = []

    for node in nodes:
        if node.role != "supernode" or node.status != "running" or not node.ip:
            continue

        # Check current image
        if node.framework == framework:
            results.append({
                "node": node.name, "ip": node.ip,
                "switched": False, "success": True, "message": "already correct",
            })
            continue

        sl_addr = superlink_ip or node.superlink_address
        docker_run = (
            f"docker stop {SUPERNODE_CONTAINER} 2>/dev/null; "
            f"docker rm {SUPERNODE_CONTAINER} 2>/dev/null; "
            f"docker run -d --name {SUPERNODE_CONTAINER} --restart unless-stopped "
            f"-v /opt/flower/data:/app/data:ro "
            f"{image} "
            f"--insecure --superlink {sl_addr}:9092 "
            f"--isolation subprocess "
            f"--max-retries 0 --max-wait-time 0"
        )
        rc, out = _ssh(node.ip, docker_run, timeout=30)
        results.append({
            "node": node.name, "ip": node.ip,
            "switched": True, "success": rc == 0,
            "message": "ok" if rc == 0 else out,
        })

    return results


# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------
def collect_nodes() -> list[NodeInfo]:
    """Get all Flower VMs from OpenNebula."""
    nodes = []
    rc, out = _run("onevm list -j 2>/dev/null")
    if rc != 0:
        return nodes

    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return nodes

    vm_pool = data.get("VM_POOL", {})
    if not vm_pool:
        return nodes

    vms = vm_pool.get("VM", [])
    if isinstance(vms, dict):
        vms = [vms]

    for vm in vms:
        name = vm.get("NAME", "")
        name_lower = name.lower()
        if not any(kw in name_lower for kw in ("flower", "superlink", "supernode")):
            continue

        # Determine role
        role = "superlink" if "superlink" in name.lower() else "supernode"

        # Get IP
        template = vm.get("TEMPLATE", {})
        nic = template.get("NIC", {})
        if isinstance(nic, list):
            nic = nic[0] if nic else {}
        ip = nic.get("IP", "")

        # Get context for SuperLink address
        context = template.get("CONTEXT", {})
        superlink_addr = context.get("ONEAPP_FL_SUPERLINK_ADDRESS", "")

        # State mapping
        lcm_state = int(vm.get("LCM_STATE", 0))
        state_map = {3: "running", 5: "stopped", 36: "unknown"}
        status = state_map.get(lcm_state, "other")

        cpu = int(template.get("VCPU", template.get("CPU", 0)))
        memory = int(template.get("MEMORY", 0))

        node = NodeInfo(
            vm_id=int(vm.get("ID", 0)),
            name=name,
            role=role,
            ip=ip,
            status=status,
            cpu=cpu,
            memory_mb=memory,
            superlink_address=superlink_addr,
        )
        nodes.append(node)

    return nodes


def collect_container_info(node: NodeInfo) -> NodeInfo:
    """Enrich a node with Docker container info via SSH."""
    if not node.ip or node.status != "running":
        return node

    container = SUPERLINK_CONTAINER if node.role == "superlink" else SUPERNODE_CONTAINER

    rc, out = _ssh(node.ip, f"docker inspect {container} --format '{{{{.State.Status}}}} {{{{.State.StartedAt}}}} {{{{.Config.Image}}}}'")
    if rc == 0 and out:
        parts = out.split()
        if len(parts) >= 3:
            node.container_status = parts[0]
            # Calculate uptime
            try:
                started = datetime.fromisoformat(parts[1].replace("Z", "+00:00"))
                delta = datetime.now(timezone.utc) - started
                hours, remainder = divmod(int(delta.total_seconds()), 3600)
                minutes, _ = divmod(remainder, 60)
                node.container_uptime = f"{hours}h {minutes}m"
            except (ValueError, TypeError):
                node.container_uptime = "unknown"
            node.flower_version = parts[2].split(":")[-1] if ":" in parts[2] else parts[2]
            # Detect framework from Docker image name
            image_name = parts[2].lower()
            for fw in ("pytorch", "tensorflow", "sklearn"):
                if fw in image_name:
                    node.framework = fw
                    break
    else:
        node.container_status = "not found"

    return node


MODEL_INFO = {
    "pytorch": {
        "architecture": "SimpleCNN (Conv2d -> Conv2d -> FC -> FC)",
        "parameters": "~878K",
        "framework": "PyTorch 2.6.0",
        "dataset": "CIFAR-10",
        "strategy": "FedAvg",
    },
    "tensorflow": {
        "architecture": "Sequential CNN (Conv2D -> Conv2D -> Dense -> Dense)",
        "parameters": "~880K",
        "framework": "TensorFlow 2.18.1",
        "dataset": "CIFAR-10",
        "strategy": "FedAvg",
    },
    "sklearn": {
        "architecture": "MLPClassifier (3072 -> 512 -> 10)",
        "parameters": "~1.6M",
        "framework": "scikit-learn 1.4+",
        "dataset": "CIFAR-10 (flattened)",
        "strategy": "FedAvg",
    },
}


def collect_training_logs(superlink_ip: str, framework: str = "") -> RunInfo:
    """Parse SuperLink logs for training metrics.

    Only parses logs from the LATEST run (from the last "Starting run"
    line onwards) so previous runs don't bleed through.
    """
    run_info = RunInfo()

    if not superlink_ip:
        return run_info

    rc, out = _ssh(superlink_ip, f"docker logs {SUPERLINK_CONTAINER} 2>&1", timeout=10)
    if rc != 0:
        return run_info

    all_lines = out.split("\n")

    # Scope to the latest run only
    last_start_idx = 0
    for i, line in enumerate(all_lines):
        if re.search(r"Starting run \d+", line):
            last_start_idx = i
    lines = all_lines[last_start_idx:]

    # Extract run ID
    for line in lines:
        m = re.search(r"Starting run (\d+)", line)
        if m:
            run_info.run_id = m.group(1)

    # Extract num_rounds from config
    for line in lines:
        m = re.search(r"num_rounds=(\d+)", line)
        if m:
            run_info.num_rounds_configured = int(m.group(1))

    # Parse rounds
    current_round = 0
    rounds = {}
    for line in lines:
        # Round start
        m = re.search(r"\[ROUND (\d+)\]", line)
        if m:
            current_round = int(m.group(1))
            if current_round not in rounds:
                rounds[current_round] = RoundMetrics(round_num=current_round)

        # Fit aggregation
        m = re.search(r"aggregate_fit: received (\d+) results? and (\d+) failures?", line)
        if m and current_round in rounds:
            rounds[current_round].fit_clients = int(m.group(1))
            rounds[current_round].fit_failures = int(m.group(2))

        # Evaluate aggregation
        m = re.search(r"aggregate_evaluate: received (\d+) results? and (\d+) failures?", line)
        if m and current_round in rounds:
            rounds[current_round].eval_clients = int(m.group(1))
            rounds[current_round].eval_failures = int(m.group(2))

    # Parse history (loss per round)
    loss_section = False
    accuracy_section = False
    for line in lines:
        if "History (loss" in line:
            loss_section = True
            accuracy_section = False
            continue
        if "History (metrics" in line or "History (accuracy" in line:
            accuracy_section = True
            loss_section = False
            continue
        if loss_section or accuracy_section:
            m = re.search(r"round (\d+): ([\d.]+)", line)
            if m:
                rnum = int(m.group(1))
                val = float(m.group(2))
                if rnum not in rounds:
                    rounds[rnum] = RoundMetrics(round_num=rnum)
                if loss_section:
                    rounds[rnum].loss = val
                elif accuracy_section:
                    rounds[rnum].accuracy = val

    run_info.rounds = [asdict(r) for r in sorted(rounds.values(), key=lambda x: x.round_num)]
    run_info.num_rounds_completed = len(rounds)

    # Determine run status
    for line in lines:
        if "Run finished" in line:
            run_info.status = "completed"
            m = re.search(r"in ([\d.]+)s", line)
            if m:
                run_info.total_duration_s = float(m.group(1))
            break
    else:
        if run_info.run_id:
            run_info.status = "running"

    # Count connected SuperNodes from Fleet API messages
    node_ids = set()
    for line in all_lines[-200:]:  # Last 200 lines from full log
        m = re.search(r"node_id=(\d+)", line)
        if m:
            node_ids.add(m.group(1))

    # Get model info based on detected framework
    run_info.model_info = MODEL_INFO.get(framework, MODEL_INFO.get("pytorch", {}))

    return run_info


def collect_connected_nodes(superlink_ip: str) -> int:
    """Count unique SuperNode IDs from recent Fleet API messages."""
    if not superlink_ip:
        return 0
    rc, out = _ssh(superlink_ip, f"docker logs {SUPERLINK_CONTAINER} 2>&1 | tail -100")
    if rc != 0:
        return 0
    node_ids = set()
    for line in out.split("\n"):
        m = re.search(r"\[Fleet\.PullMessages\] node_id=(\d+)", line)
        if m:
            node_ids.add(m.group(1))
    return len(node_ids)


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------
@app.get("/api/cluster")
async def get_cluster_state():
    """Return full cluster state as JSON."""
    nodes = collect_nodes()

    # Enrich with container info in parallel
    for node in nodes:
        collect_container_info(node)

    superlink_ip = ""
    framework = ""
    for node in nodes:
        if node.role == "superlink" and node.status == "running":
            superlink_ip = node.ip
        if node.role == "supernode" and node.framework:
            framework = node.framework

    process_running = _active_training and _active_training.process.poll() is None
    training_active = process_running or _monitoring_run

    if _training_reset and not training_active:
        run_info = RunInfo()
    else:
        run_info = collect_training_logs(superlink_ip, framework)
        # If training is active but SuperLink still shows old completed
        # data (new run hasn't registered yet), show running state
        if training_active and run_info.status in ("completed", "idle", ""):
            run_info = RunInfo(status="running")
    connected = collect_connected_nodes(superlink_ip)

    state = ClusterState(
        timestamp=datetime.now(timezone.utc).isoformat(),
        nodes=[asdict(n) for n in nodes],
        current_run=asdict(run_info),
        connected_supernodes=connected,
        superlink_ip=superlink_ip,
    )
    return asdict(state)


@app.get("/", response_class=HTMLResponse)
async def index():
    """Serve the dashboard."""
    html_path = Path(__file__).parent / "static" / "index.html"
    return HTMLResponse(html_path.read_text())


# ---------------------------------------------------------------------------
# Training control endpoints
# ---------------------------------------------------------------------------
@app.get("/api/frameworks")
async def get_frameworks():
    """Scan demo dir for available frameworks, parse defaults from pyproject.toml."""
    frameworks = []
    defaults = {}

    for subdir in sorted(DEMO_BASE.iterdir()):
        pyproject = subdir / "pyproject.toml"
        if not subdir.is_dir() or not pyproject.exists():
            continue
        frameworks.append(subdir.name)
        if not defaults:
            with open(pyproject, "rb") as f:
                data = tomllib.load(f)
            defaults = data.get("tool", {}).get("flwr", {}).get("app", {}).get("config", {})

    # Detect cluster framework from running nodes
    cluster_framework = ""
    nodes = collect_nodes()
    for node in nodes:
        if node.role == "supernode" and node.status == "running":
            collect_container_info(node)
            if node.framework:
                cluster_framework = node.framework
                break

    return {
        "frameworks": frameworks,
        "cluster_framework": cluster_framework,
        "strategies": ["FedAvg", "FedProx", "FedAdam"],
        "defaults": defaults,
    }


@app.post("/api/training/start")
async def start_training(req: TrainingRequest):
    """Launch a Flower training run as a subprocess.

    If the requested framework differs from what the cluster is running,
    the SuperNode containers are automatically restarted with the correct image.
    """
    global _active_training, _last_completed, _training_reset, _monitoring_run, _superlink_ip_cache

    if _active_training and _active_training.process.poll() is None:
        raise HTTPException(status_code=409, detail="Training already in progress")
    if _monitoring_run:
        raise HTTPException(status_code=409, detail="Training already in progress on the cluster")

    # Clear stale results from previous run
    _last_completed = None
    _training_reset = False
    _monitoring_run = False

    # --- Auto-switch SuperNode framework if needed ---
    switch_results = []
    nodes = collect_nodes()
    for node in nodes:
        collect_container_info(node)

    superlink_ip = ""
    cluster_framework = ""
    for node in nodes:
        if node.role == "superlink" and node.status == "running":
            superlink_ip = node.ip
        if node.role == "supernode" and node.framework:
            cluster_framework = node.framework

    _superlink_ip_cache = superlink_ip

    needs_switch = cluster_framework and cluster_framework != req.framework
    if needs_switch:
        switch_results = _switch_supernode_framework(nodes, req.framework, superlink_ip)
        failures = [r for r in switch_results if not r["success"]]
        if failures:
            detail = "; ".join(f"{r['node']}: {r['message']}" for r in failures)
            raise HTTPException(status_code=500, detail=f"Framework switch failed: {detail}")
        # Give containers time to register with SuperLink
        time.sleep(5)

    # Build --run-config string (string values must be double-quoted for flwr)
    def _cfg(k, v):
        if isinstance(v, str):
            return f'{k}="{v}"'
        return f"{k}={v}"

    config_parts = [
        _cfg("num-server-rounds", req.num_rounds),
        _cfg("local-epochs", req.local_epochs),
        _cfg("batch-size", req.batch_size),
        _cfg("strategy", req.strategy),
        _cfg("min-fit-clients", req.min_fit_clients),
        _cfg("min-available-clients", req.min_available_clients),
    ]
    for k, v in req.extra_config.items():
        config_parts.append(_cfg(k, v))
    run_config_str = " ".join(config_parts)

    cmd = [str(FLWR_BIN), "run", ".", "opennebula", "--run-config", run_config_str]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        cwd=str(DEMO_BASE / req.framework),
    )

    output_lines = deque(maxlen=500)
    t = threading.Thread(target=_reader_thread, args=(proc, output_lines), daemon=True)
    t.start()

    _active_training = ActiveTraining(
        process=proc,
        framework=req.framework,
        config=req.model_dump(),
        started_at=time.time(),
        output_lines=output_lines,
    )

    return {
        "status": "started",
        "pid": proc.pid,
        "framework": req.framework,
        "switched": needs_switch,
        "switch_results": switch_results,
    }


@app.get("/api/training/status")
async def get_training_status():
    """Return current training status."""
    global _active_training, _last_completed

    # flwr run process still running
    if _active_training and _active_training.process.poll() is None:
        return {
            "active": True,
            "phase": "submitting",
            "framework": _active_training.framework,
            "config": _active_training.config,
            "elapsed_s": round(time.time() - _active_training.started_at, 1),
            "lines": list(_active_training.output_lines)[-20:],
        }

    # flwr run process finished — clean up reference but don't set _last_completed
    # if monitoring continues (the SSE handler sets _monitoring_run)
    if _active_training and _active_training.process.poll() is not None:
        if not _monitoring_run:
            _last_completed = {
                "framework": _active_training.framework,
                "config": _active_training.config,
                "duration_s": round(time.time() - _active_training.started_at, 1),
                "exit_code": _active_training.process.returncode,
                "last_lines": list(_active_training.output_lines)[-20:],
            }
        _active_training = None

    # Training running on SuperLink (flwr run already exited)
    if _monitoring_run:
        return {
            "active": True,
            "phase": "training",
        }

    return {
        "active": False,
        "last_completed": _last_completed,
    }


@app.get("/api/training/log")
async def stream_training_log():
    """SSE endpoint to tail training output.

    Phase 1: streams flwr run process stdout.
    Phase 2: after flwr run exits successfully (job submitted), switches
    to tailing SuperLink docker logs until "Run finished" is detected.
    """
    async def event_generator():
        global _monitoring_run

        # --- Phase 1: stream flwr run process output ---
        seen = 0
        submitted = False
        while _active_training:
            lines = list(_active_training.output_lines)
            if len(lines) > seen:
                for line in lines[seen:]:
                    yield f"data: {json.dumps({'line': line})}\n\n"
                    if "Successfully started run" in line:
                        submitted = True
                seen = len(lines)

            if _active_training.process.poll() is not None:
                # Flush remaining
                lines = list(_active_training.output_lines)
                for line in lines[seen:]:
                    yield f"data: {json.dumps({'line': line})}\n\n"
                    if "Successfully started run" in line:
                        submitted = True
                break

            await asyncio.sleep(0.5)

        if not submitted:
            # flwr run failed or wasn't a submission — done
            yield "event: complete\ndata: {}\n\n"
            return

        # --- Phase 2: tail SuperLink logs for real training progress ---
        _monitoring_run = True
        yield f"data: {json.dumps({'line': ''})}\n\n"
        yield f"data: {json.dumps({'line': '--- Monitoring training on SuperLink ---'})}\n\n"

        sl_ip = _superlink_ip_cache
        seen_sl = 0
        while _monitoring_run:
            if not sl_ip:
                await asyncio.sleep(3)
                continue

            rc, out = _ssh(sl_ip, f"docker logs {SUPERLINK_CONTAINER} 2>&1", timeout=10)
            if rc != 0:
                await asyncio.sleep(3)
                continue

            sl_lines = out.split("\n")

            # Scope to latest run
            last_start = 0
            for i, line in enumerate(sl_lines):
                if re.search(r"Starting run \d+", line):
                    last_start = i
            scoped = sl_lines[last_start:]

            if len(scoped) > seen_sl:
                for line in scoped[seen_sl:]:
                    yield f"data: {json.dumps({'line': line})}\n\n"
                seen_sl = len(scoped)

                # Check for completion
                for line in scoped:
                    if "Run finished" in line:
                        _monitoring_run = False
                        yield "event: complete\ndata: {}\n\n"
                        return

            await asyncio.sleep(2)

        yield "event: complete\ndata: {}\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")


@app.post("/api/training/stop")
async def stop_training():
    """Stop the active training run."""
    global _active_training, _last_completed, _monitoring_run

    if _active_training and _active_training.process.poll() is None:
        proc = _active_training.process
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)

        _last_completed = {
            "framework": _active_training.framework,
            "config": _active_training.config,
            "duration_s": round(time.time() - _active_training.started_at, 1),
            "exit_code": proc.returncode,
            "last_lines": list(_active_training.output_lines)[-20:],
        }
        _active_training = None
        _monitoring_run = False
        return {"status": "stopped"}

    if _monitoring_run:
        _monitoring_run = False
        _active_training = None
        return {"status": "stopped"}

    raise HTTPException(status_code=404, detail="No active training to stop")


@app.post("/api/training/reset")
async def reset_training():
    """Clear stale training results so the dashboard shows a clean slate."""
    global _last_completed, _training_reset, _monitoring_run

    _last_completed = None
    _training_reset = True
    _monitoring_run = False
    return {"status": "reset"}


@app.post("/api/upload")
async def upload_dataset(file: UploadFile = File(...)):
    """Upload a file and SCP it to all supernodes."""
    MAX_SIZE = 500 * 1024 * 1024  # 500 MB

    # Save to tempfile
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=f"_{file.filename}")
    try:
        size = 0
        while chunk := await file.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_SIZE:
                os.unlink(tmp.name)
                raise HTTPException(status_code=413, detail="File exceeds 500MB limit")
            tmp.write(chunk)
        tmp.close()

        # SCP to each supernode
        nodes = collect_nodes()
        results = []
        for node in nodes:
            if node.role != "supernode" or node.status != "running":
                continue
            rc, out = _run(
                f"scp {SSH_OPTS} {tmp.name} {SSH_USER}@{node.ip}:/opt/flower/data/{file.filename}",
                timeout=60,
            )
            results.append({
                "node": node.name,
                "ip": node.ip,
                "success": rc == 0,
                "message": out if rc != 0 else "ok",
            })

        return {"filename": file.filename, "size_bytes": size, "nodes": results}
    finally:
        if os.path.exists(tmp.name):
            os.unlink(tmp.name)
