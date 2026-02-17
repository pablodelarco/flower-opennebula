#!/usr/bin/env bash
# quickstart.sh — From "cluster deployed" to "training running" in one command.
#
# Usage:
#   bash demo/quickstart.sh                          # interactive
#   bash demo/quickstart.sh --auto                   # non-interactive (CI/scripting)
#   bash demo/quickstart.sh --skip-cluster           # local simulation only
#   bash demo/quickstart.sh --superlink 10.0.0.5:9093  # skip discovery
#   bash demo/quickstart.sh --service-id 42          # skip service search
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
SUPERLINK_PORT=9093
CONNECTIVITY_TIMEOUT=5
DEPLOY_WAIT_INTERVAL=10
DEPLOY_WAIT_MAX=180

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Defaults (overridable via flags) ─────────────────────────────────────────
AUTO=false
SKIP_CLUSTER=false
SERVICE_ID=""
SUPERLINK=""
DEMO_DIR=""
CLUSTER_FRAMEWORK=""
SUPERNODE_IPS=""
SERVICE_SHOW_JSON=""

# ── Colors (disabled when not a terminal) ────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD='\033[1m'    DIM='\033[2m'
    GREEN='\033[0;32m' YELLOW='\033[0;33m' RED='\033[0;31m' CYAN='\033[0;36m'
    RESET='\033[0m'
else
    BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}▸${RESET} $*"; }
success() { echo -e "${GREEN}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*" >&2; }
error()   { echo -e "${RED}✗${RESET} $*" >&2; }
die()     { error "$@"; exit 1; }
stage()   { echo; echo -e "${BOLD}── Stage $1: $2 ──${RESET}"; }
hint()    { echo -e "  ${DIM}$*${RESET}"; }

prompt_yn() {
    local prompt="$1" default="${2:-y}"
    if $AUTO; then return 0; fi
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${CYAN}?${RESET}") $prompt [Y/n] " yn
        [[ -z "$yn" || "$yn" =~ ^[Yy] ]]
    else
        read -rp "$(echo -e "${CYAN}?${RESET}") $prompt [y/N] " yn
        [[ "$yn" =~ ^[Yy] ]]
    fi
}

prompt_choice() {
    local prompt="$1"; shift
    local options=("$@")

    if $AUTO || [[ ${#options[@]} -eq 1 ]]; then
        REPLY="${options[0]}"
        info "Selected: $REPLY"
        return
    fi

    echo -e "${CYAN}?${RESET} $prompt"
    local i
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done

    local choice
    while true; do
        read -rp "  Enter number [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            REPLY="${options[$((choice-1))]}"
            return
        fi
        warn "Invalid choice. Try again."
    done
}

# ── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)         AUTO=true; shift ;;
            --skip-cluster) SKIP_CLUSTER=true; shift ;;
            --service-id)   SERVICE_ID="${2:?--service-id requires a value}"; shift 2 ;;
            --superlink)    SUPERLINK="${2:?--superlink requires ip:port}"; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            *)              die "Unknown option: $1 (try --help)" ;;
        esac
    done
}

usage() {
    cat <<'EOF'
Flower FL Quickstart — deploy your first federated training run.

Usage:
  bash demo/quickstart.sh [OPTIONS]

Options:
  --auto               Skip all prompts (accept defaults)
  --skip-cluster       Run local simulation only (no cluster needed)
  --service-id ID      Use this OneFlow service (skip discovery)
  --superlink IP:PORT  Connect directly to SuperLink (skip discovery)
  -h, --help           Show this help

Examples:
  bash demo/quickstart.sh                            # interactive walkthrough
  bash demo/quickstart.sh --auto                     # CI / scripting
  bash demo/quickstart.sh --skip-cluster             # local sim only
  bash demo/quickstart.sh --superlink 10.0.0.5:9093  # known endpoint
EOF
}

# ── Stage 1: Prerequisites ───────────────────────────────────────────────────
check_prerequisites() {
    stage 1 "Prerequisites"

    local missing=()

    # Python 3.11+
    if command -v python3 &>/dev/null; then
        local pyver
        pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
        local pymajor pyminor
        pymajor="${pyver%%.*}"
        pyminor="${pyver#*.}"
        if (( pymajor < 3 || (pymajor == 3 && pyminor < 11) )); then
            die "Python 3.11+ required (found $pyver). Install it with:
  sudo apt install python3.11   # or
  pyenv install 3.11"
        fi
        success "Python $pyver"
    else
        die "python3 not found. Install it with:
  sudo apt install python3"
    fi

    # jq
    if command -v jq &>/dev/null; then
        success "jq $(jq --version 2>/dev/null || echo 'available')"
    else
        warn "jq not found. Install it with:"
        hint "sudo apt install jq"
        missing+=(jq)
    fi

    # oneflow (only needed for cluster discovery)
    if ! $SKIP_CLUSTER && [[ -z "$SUPERLINK" ]]; then
        if command -v oneflow &>/dev/null; then
            success "oneflow CLI"
        else
            warn "oneflow CLI not found — cluster auto-discovery unavailable."
            echo
            hint "You can still run training by providing the SuperLink address directly:"
            hint "  bash demo/quickstart.sh --superlink <SUPERLINK_IP>:9093"
            echo
            hint "Or run a local simulation without any cluster:"
            hint "  bash demo/quickstart.sh --skip-cluster"
            echo
            if ! $AUTO; then
                prompt_yn "Continue without cluster discovery?" "n" || exit 1
                SKIP_CLUSTER=true
            else
                missing+=(oneflow)
            fi
        fi
    fi

    # nc (for connectivity check)
    if ! $SKIP_CLUSTER; then
        if command -v nc &>/dev/null; then
            success "nc (netcat)"
        else
            warn "nc not found — will skip connectivity check"
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing[*]}"
    fi

    success "All prerequisites met"
}

# ── Stage 2: Cluster discovery ───────────────────────────────────────────────
discover_cluster() {
    stage 2 "Cluster discovery"

    if $SKIP_CLUSTER; then
        info "Skipping cluster discovery (--skip-cluster)"
        return
    fi

    # If user provided --superlink, validate and use it directly
    if [[ -n "$SUPERLINK" ]]; then
        local sl_host sl_port
        sl_host="${SUPERLINK%%:*}"
        sl_port="${SUPERLINK##*:}"
        : "${sl_port:=$SUPERLINK_PORT}"
        SUPERLINK="${sl_host}:${sl_port}"
        info "Using provided SuperLink: $SUPERLINK"
        check_superlink_reachable "$sl_host" "$sl_port"
        return
    fi

    # If user provided --service-id, use it directly
    if [[ -n "$SERVICE_ID" ]]; then
        info "Using provided service ID: $SERVICE_ID"
        wait_for_service_running "$SERVICE_ID"
        extract_superlink_ip "$SERVICE_ID"
        return
    fi

    # Discover via oneflow
    discover_via_oneflow
}

discover_via_oneflow() {
    info "Searching for Flower FL services..."

    local services_json
    services_json="$(oneflow list --json 2>/dev/null)" \
        || die "Failed to query OneFlow. Is the OpenNebula daemon running?"

    # oneflow list --json returns a flat array on OpenNebula 7.0+
    local service_ids
    mapfile -t service_ids < <(
        echo "$services_json" \
        | jq -r '.[] | select(.TEMPLATE.BODY.name | test("[Ff]lower"; "i"))
                 | select(.TEMPLATE.BODY.state == 2)
                 | .ID' 2>/dev/null
    )

    # Also check for non-running services if none found
    if [[ ${#service_ids[@]} -eq 0 || ( ${#service_ids[@]} -eq 1 && -z "${service_ids[0]}" ) ]]; then
        # Check if there are any Flower services at all (any state)
        local all_flower_ids
        mapfile -t all_flower_ids < <(
            echo "$services_json" \
            | jq -r '.[] | select(.TEMPLATE.BODY.name | test("[Ff]lower"; "i")) | .ID' 2>/dev/null
        )

        if [[ ${#all_flower_ids[@]} -eq 0 || ( ${#all_flower_ids[@]} -eq 1 && -z "${all_flower_ids[0]}" ) ]]; then
            error "No Flower FL services found."
            echo
            echo -e "${BOLD}To deploy a Flower cluster:${RESET}"
            echo
            echo "  1. List available service templates:"
            hint "oneflow-template list"
            echo
            echo "  2. Instantiate the Flower service template:"
            hint "oneflow-template instantiate <TEMPLATE_ID>"
            echo
            echo "  3. Wait for RUNNING state, then re-run this script."
            echo
            echo -e "${BOLD}Or skip cluster discovery:${RESET}"
            hint "bash demo/quickstart.sh --superlink <IP>:9093    # known SuperLink"
            hint "bash demo/quickstart.sh --skip-cluster           # local sim only"
            exit 1
        else
            # Services exist but none are RUNNING
            local states
            states="$(echo "$services_json" \
                | jq -r '.[] | select(.TEMPLATE.BODY.name | test("[Ff]lower"; "i"))
                         | "  ID \(.ID): state \(.TEMPLATE.BODY.state) (\(.TEMPLATE.BODY.log[-1].message // "unknown"))"' 2>/dev/null)"
            warn "Found Flower services but none are in RUNNING state (2):"
            echo "$states"
            echo
            hint "Wait for deployment to complete, or check with: oneflow show <ID>"
            exit 1
        fi
    fi

    # Pick a service
    local sid
    if [[ ${#service_ids[@]} -eq 1 ]]; then
        sid="${service_ids[0]}"
        local sname
        sname="$(echo "$services_json" | jq -r ".[] | select(.ID == \"$sid\") | .TEMPLATE.BODY.name")"
        success "Found: $sname (ID $sid)"
    else
        local display_names=()
        for id in "${service_ids[@]}"; do
            local name
            name="$(echo "$services_json" \
                | jq -r ".[] | select(.ID == \"$id\") | .TEMPLATE.BODY.name")"
            display_names+=("$id — $name")
        done
        prompt_choice "Multiple Flower services found. Which one?" "${display_names[@]}"
        sid="${REPLY%% *}"
    fi

    info "Using service ID: $sid"
    extract_superlink_ip "$sid"
}

extract_superlink_ip() {
    local sid="$1"

    local show_json
    show_json="$(oneflow show "$sid" --json 2>/dev/null)" \
        || die "Failed to query service $sid. Check with: oneflow show $sid"
    SERVICE_SHOW_JSON="$show_json"

    # Get the SuperLink VM ID from the service
    local superlink_vm_id
    superlink_vm_id="$(echo "$show_json" \
        | jq -r '.DOCUMENT.TEMPLATE.BODY.roles[]
                  | select(.name == "superlink")
                  | .nodes[0].deploy_id' 2>/dev/null)"

    if [[ -z "$superlink_vm_id" || "$superlink_vm_id" == "null" ]]; then
        error "Could not find SuperLink VM in service $sid."
        hint "Check service status: oneflow show $sid"
        exit 1
    fi

    info "SuperLink VM ID: $superlink_vm_id"

    # Get the IP from the VM directly
    local superlink_ip
    superlink_ip="$(onevm show "$superlink_vm_id" --json 2>/dev/null \
        | jq -r '.VM.TEMPLATE.NIC[0].IP // .VM.TEMPLATE.NIC.IP' 2>/dev/null)"

    if [[ -z "$superlink_ip" || "$superlink_ip" == "null" ]]; then
        error "Could not get IP for SuperLink VM $superlink_vm_id."
        hint "Check VM: onevm show $superlink_vm_id"
        exit 1
    fi

    SUPERLINK="${superlink_ip}:${SUPERLINK_PORT}"
    success "SuperLink: $SUPERLINK"

    # Extract framework from cluster template
    CLUSTER_FRAMEWORK="$(echo "$show_json" \
        | jq -r '.DOCUMENT.TEMPLATE.BODY.roles[]
                  | select(.name == "supernode")
                  | .vm_template_contents' 2>/dev/null \
        | grep -oP 'ONEAPP_FL_FRAMEWORK\s*=\s*"\$?(\K[^"]+)' | head -1)" || true
    if [[ -n "$CLUSTER_FRAMEWORK" ]]; then
        info "Cluster framework: $CLUSTER_FRAMEWORK"
    fi

    # Extract SuperNode IPs
    local sn_vm_ids
    mapfile -t sn_vm_ids < <(echo "$show_json" \
        | jq -r '.DOCUMENT.TEMPLATE.BODY.roles[]
                  | select(.name == "supernode")
                  | .nodes[].deploy_id' 2>/dev/null)

    local ips=()
    for vmid in "${sn_vm_ids[@]}"; do
        [[ -z "$vmid" || "$vmid" == "null" ]] && continue
        local ip
        ip="$(onevm show "$vmid" --json 2>/dev/null \
            | jq -r '.VM.TEMPLATE.NIC[0].IP // .VM.TEMPLATE.NIC.IP' 2>/dev/null)" || true
        [[ -n "$ip" && "$ip" != "null" ]] && ips+=("$ip")
    done
    SUPERNODE_IPS="${ips[*]}"

    # Show cluster overview
    info "Cluster: 1 SuperLink + ${#ips[@]} SuperNodes"

    check_superlink_reachable "$superlink_ip" "$SUPERLINK_PORT"
}

wait_for_service_running() {
    local sid="$1"
    local elapsed=0

    while true; do
        local state
        state="$(oneflow show "$sid" --json \
            | jq -r '.DOCUMENT.TEMPLATE.BODY.state' 2>/dev/null)"

        if [[ "$state" == "2" ]]; then
            success "Service $sid is RUNNING"
            return
        fi

        # States that mean "still deploying" (1=DEPLOYING, 11=DEPLOYING_NETS, etc.)
        if [[ "$state" =~ ^(1|11)$ ]]; then
            if (( elapsed >= DEPLOY_WAIT_MAX )); then
                error "Service $sid still deploying after ${DEPLOY_WAIT_MAX}s."
                hint "Check status:  oneflow show $sid"
                hint "Check logs:    journalctl -u opennebula-flow --since '5 min ago'"
                exit 1
            fi
            info "Service is deploying... waiting (${elapsed}s / ${DEPLOY_WAIT_MAX}s)"
            sleep "$DEPLOY_WAIT_INTERVAL"
            (( elapsed += DEPLOY_WAIT_INTERVAL ))
        else
            error "Service $sid is in state $state (expected 2=RUNNING)."
            hint "Check status: oneflow show $sid"
            exit 1
        fi
    done
}

check_superlink_reachable() {
    local host="$1" port="$2"

    if ! command -v nc &>/dev/null; then
        warn "Skipping connectivity check (nc not available)"
        return
    fi

    info "Checking connectivity to ${host}:${port}..."
    if nc -z -w "$CONNECTIVITY_TIMEOUT" "$host" "$port" 2>/dev/null; then
        success "SuperLink is reachable"
    else
        warn "Cannot reach ${host}:${port}"
        hint "The cluster may still be starting containers (wait ~30s and retry)."
        hint "Or check: ssh root@${host} docker ps"
        if ! $AUTO; then
            prompt_yn "Continue anyway?" "y" || exit 1
        fi
    fi
}

# ── Stage 3: Framework selection ─────────────────────────────────────────────
select_framework() {
    stage 3 "Framework selection"

    local demos=()
    local demo_base="$SCRIPT_DIR"

    for dir in "$demo_base"/*/; do
        [[ -f "${dir}pyproject.toml" ]] && demos+=("$(basename "$dir")")
    done

    if [[ ${#demos[@]} -eq 0 ]]; then
        error "No demo projects found in $demo_base/."
        hint "Expected directories with pyproject.toml (e.g., pytorch/, tensorflow/, sklearn/)."
        hint "Make sure you cloned the full repo: git clone https://github.com/pablodelarco/flower-opennebula"
        exit 1
    fi

    # Auto-detect from cluster if available
    if [[ -n "$CLUSTER_FRAMEWORK" ]]; then
        local detected="$CLUSTER_FRAMEWORK"
        # Check if a matching demo exists
        local match=""
        for d in "${demos[@]}"; do
            if [[ "$d" == "$detected" ]]; then
                match="$d"
                break
            fi
        done

        if [[ -n "$match" ]]; then
            info "Cluster is configured for ${BOLD}${match}${RESET}"
            if $AUTO; then
                REPLY="$match"
                info "Selected: $REPLY (auto-detected from cluster)"
            else
                prompt_choice "Which demo would you like to run? (cluster uses $match)" "${demos[@]}"
                if [[ "$REPLY" != "$match" ]]; then
                    warn "You selected '$REPLY' but the cluster SuperNodes have '$match' containers."
                    warn "Training will fail unless you redeploy with the matching framework."
                    prompt_yn "Continue anyway?" "n" || exit 1
                fi
            fi
        else
            warn "Cluster framework '$detected' has no matching demo in $demo_base/"
            prompt_choice "Which demo would you like to run?" "${demos[@]}"
        fi
    else
        prompt_choice "Which demo would you like to run?" "${demos[@]}"
    fi

    DEMO_DIR="$demo_base/$REPLY"
    success "Selected: $REPLY"
}

# ── Stage 4: Python environment setup ────────────────────────────────────────
setup_venv() {
    stage 4 "Python environment"

    local venv_dir="$DEMO_DIR/.venv"

    if [[ -d "$venv_dir" ]]; then
        info "Existing venv found"
        if prompt_yn "Reuse existing venv?" "y"; then
            source "$venv_dir/bin/activate"
            success "Activated existing venv"
            return
        fi
    fi

    info "Creating virtual environment..."
    python3 -m venv "$venv_dir"
    source "$venv_dir/bin/activate"
    success "Created and activated venv"

    info "Installing dependencies (this may take a few minutes)..."
    pip install --upgrade pip --quiet 2>&1 | tail -1 || true
    if ! pip install -e "$DEMO_DIR" --quiet 2>&1; then
        error "pip install failed."
        hint "Check $DEMO_DIR/pyproject.toml for dependency issues."
        hint "Try manually: cd $DEMO_DIR && pip install -e ."
        exit 1
    fi

    success "Dependencies installed"
}

# ── Stage 5: Configure federation ────────────────────────────────────────────
configure_federation() {
    stage 5 "Configure federation"

    if $SKIP_CLUSTER; then
        info "Skipping federation config (--skip-cluster)"
        return
    fi

    local sl_host="${SUPERLINK%%:*}"
    local sl_port="${SUPERLINK##*:}"
    local address="${sl_host}:${sl_port}"

    # Flower 1.25+ stores connection config in ~/.flwr/config.toml
    local flwr_config="$HOME/.flwr/config.toml"

    if [[ -f "$flwr_config" ]]; then
        info "Patching SuperLink address in $flwr_config..."

        if grep -q '\[superlink\.opennebula\]' "$flwr_config"; then
            # Replace existing address under [superlink.opennebula]
            sed -i '/\[superlink\.opennebula\]/,/^\[/{s|address = ".*"|address = "'"$address"'"|;}' "$flwr_config"
            success "Updated address → $address"
        else
            # Add new [superlink.opennebula] section
            printf '\n[superlink.opennebula]\naddress = "%s"\ninsecure = true\n' "$address" >> "$flwr_config"
            success "Added [superlink.opennebula] → $address"
        fi

        # Ensure opennebula is the default federation
        if grep -q '^default = ' "$flwr_config"; then
            sed -i 's|^default = ".*"|default = "opennebula"|' "$flwr_config"
        fi
    else
        # First run — create the config file
        info "Creating $flwr_config..."
        mkdir -p "$(dirname "$flwr_config")"
        cat > "$flwr_config" <<TOML
[superlink]
default = "opennebula"

[superlink.opennebula]
address = "$address"
insecure = true

[superlink.local-sim]
options.num-supernodes = 2
TOML
        success "Created Flower config with address → $address"
    fi

    info "Federation config:"
    grep -A3 '\[superlink\.opennebula\]' "$flwr_config" | head -5
}

# ── Stage 6: Data selection ──────────────────────────────────────────────────
select_data() {
    stage 6 "Data selection"

    if $SKIP_CLUSTER || $AUTO; then
        info "Using CIFAR-10 test dataset (auto-downloads ~170MB per node)"
        return
    fi

    echo -e "${CYAN}?${RESET} What data would you like to train on?"
    echo "  1) CIFAR-10 test dataset (auto-downloads ~170MB per node)"
    echo "  2) Your own data (expects files in /opt/flower/data/ on each SuperNode)"

    local choice
    while true; do
        read -rp "  Enter number [1-2]: " choice
        case "$choice" in
            1) info "Using CIFAR-10 test dataset"; return ;;
            2) break ;;
            *) warn "Invalid choice. Try again." ;;
        esac
    done

    # "Your own data" path
    echo
    info "Pre-stage your data on each SuperNode before training."
    echo
    echo -e "${BOLD}Upload data to each SuperNode:${RESET}"

    if [[ -n "$SUPERNODE_IPS" ]]; then
        local i=1
        for ip in $SUPERNODE_IPS; do
            hint "scp -r ./my_data/ root@${ip}:/opt/flower/data/    # SuperNode $i"
            (( i++ ))
        done
    else
        hint "scp -r ./my_data/ root@<supernode-ip>:/opt/flower/data/"
    fi

    echo
    info "Data is mounted read-only into the container at /app/data"
    info "Edit $(basename "$DEMO_DIR")/flower_demo/client_app.py to load from /app/data"
    echo

    prompt_yn "Data is staged and client_app.py is updated?" "n" || die "Stage your data first, then re-run."
}

# ── Stage 7: Optional local simulation ──────────────────────────────────────
run_local_sim() {
    stage 7 "Local simulation"

    if ! prompt_yn "Run a local simulation first? (recommended to verify setup)" "y"; then
        info "Skipping local simulation"
        return
    fi

    info "Running: flwr run . local-sim"
    echo

    (cd "$DEMO_DIR" && flwr run . local-sim)
    local rc=$?

    echo
    if [[ $rc -ne 0 ]]; then
        error "Local simulation failed (exit code $rc)."
        hint "Check the output above for errors."
        hint "Common fixes: pip install -e . (missing deps), check client_app.py imports."
        if $SKIP_CLUSTER; then
            exit 1
        fi
        if ! prompt_yn "Continue to cluster run anyway?" "n"; then
            exit 1
        fi
    else
        success "Local simulation completed successfully"
    fi
}

# ── Stage 8: Run training on cluster ────────────────────────────────────────
run_on_cluster() {
    stage 8 "Run training on cluster"

    if $SKIP_CLUSTER; then
        info "Skipping cluster run (--skip-cluster)"
        return
    fi

    info "Starting federated training on the cluster..."
    info "SuperLink: $SUPERLINK"
    info "Running: flwr run . --stream"
    echo

    # Use default federation (set to "opennebula" in ~/.flwr/config.toml)
    (cd "$DEMO_DIR" && flwr run . --stream)
    local rc=$?

    echo
    if [[ $rc -ne 0 ]]; then
        error "Training run failed (exit code $rc)."
        echo
        echo -e "${BOLD}Troubleshooting:${RESET}"
        hint "1. Check SuperLink is reachable: nc -z ${SUPERLINK%%:*} ${SUPERLINK##*:}"
        hint "2. Check containers: ssh root@${SUPERLINK%%:*} docker ps"
        hint "3. Check SuperLink logs: ssh root@${SUPERLINK%%:*} docker logs flower-superlink"
        hint "4. Verify address: grep -A2 'superlink.opennebula' ~/.flwr/config.toml"
        exit 1
    fi

    success "Training run completed"
}

# ── Stage 9: Next steps ─────────────────────────────────────────────────────
show_next_steps() {
    stage 9 "Done"

    echo
    if $SKIP_CLUSTER; then
        success "Local simulation completed successfully!"
        echo
        echo -e "${BOLD}Next steps:${RESET}"
        echo "  1. Deploy a Flower FL cluster:"
        hint "oneflow-template list                         # find the template"
        hint "oneflow-template instantiate <TEMPLATE_ID>    # deploy"
        echo "  2. Re-run this script to train on the cluster:"
        hint "bash demo/quickstart.sh"
    else
        success "Federated training completed!"
        echo
        echo -e "${BOLD}Cluster info:${RESET}"
        echo "  SuperLink: $SUPERLINK"
        echo "  Demo:      $(basename "$DEMO_DIR")"
        echo
        echo -e "${BOLD}What's next:${RESET}"
        echo
        echo "  Change strategy:"
        hint "flwr run . opennebula --run-config \"strategy=FedProx\""
        echo
        echo "  Change rounds:"
        hint "flwr run . opennebula --run-config \"num-server-rounds=10\""
        echo
        echo "  Scale the cluster:"
        hint "oneflow scale <service-id> supernode 4"
        echo
        echo "  Bring your own data:"
        if [[ -n "$SUPERNODE_IPS" ]]; then
            for ip in $SUPERNODE_IPS; do
                hint "scp -r ./my_data/ root@${ip}:/opt/flower/data/"
            done
        else
            hint "scp -r ./my_data/ root@<supernode-ip>:/opt/flower/data/"
        fi
        hint "Then edit $(basename "$DEMO_DIR")/flower_demo/client_app.py to load from /app/data"
    fi
    echo
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}Flower FL Quickstart for OpenNebula${RESET}"
    echo -e "${DIM}From deployed cluster to running training in minutes${RESET}"

    parse_args "$@"
    check_prerequisites      # Stage 1
    discover_cluster         # Stage 2
    select_framework         # Stage 3
    setup_venv               # Stage 4
    configure_federation     # Stage 5
    select_data              # Stage 6
    run_local_sim            # Stage 7
    run_on_cluster           # Stage 8
    show_next_steps          # Stage 9
}

main "$@"
