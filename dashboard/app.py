"""
Flower FL Dashboard — Real-time federated learning monitoring for OpenNebula.

Collects cluster state from OpenNebula CLI, Docker containers on each VM,
and SuperLink training logs. Serves a single-page dashboard at port 8080.
"""

import asyncio
import json
import os
import re
import subprocess
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles

app = FastAPI(title="Flower FL Dashboard")
app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SSH_USER = os.environ.get("FL_SSH_USER", "root")
SSH_OPTS = "-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
SUPERLINK_CONTAINER = "flower-superlink"
SUPERNODE_CONTAINER = "flower-supernode"


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
    """Parse SuperLink logs for training metrics."""
    run_info = RunInfo()

    if not superlink_ip:
        return run_info

    rc, out = _ssh(superlink_ip, f"docker logs {SUPERLINK_CONTAINER} 2>&1", timeout=10)
    if rc != 0:
        return run_info

    lines = out.split("\n")

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
    for line in lines[-200:]:  # Last 200 lines
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

    run_info = collect_training_logs(superlink_ip, framework)
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
