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
ONEFLOW_STATE_RUNNING=2
ONEFLOW_STATE_DEPLOYING=1
CONNECTIVITY_TIMEOUT=5
DEPLOY_WAIT_INTERVAL=10
DEPLOY_WAIT_MAX=120

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Defaults (overridable via flags) ─────────────────────────────────────────
AUTO=false
SKIP_CLUSTER=false
SERVICE_ID=""
SUPERLINK=""
DEMO_DIR=""

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

# Ask a yes/no question. Returns 0 for yes, 1 for no.
# In --auto mode, always returns 0 (yes).
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

# Ask user to pick from a list. Sets REPLY to the chosen value.
# In --auto mode, picks the first option.
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
            die "Python 3.11+ required (found $pyver)"
        fi
        success "Python $pyver"
    else
        die "python3 not found — install Python 3.11+"
    fi

    # jq
    if command -v jq &>/dev/null; then
        success "jq $(jq --version 2>/dev/null || echo 'available')"
    else
        missing+=(jq)
    fi

    # oneflow (only needed for cluster discovery)
    if ! $SKIP_CLUSTER && [[ -z "$SUPERLINK" ]]; then
        if command -v oneflow &>/dev/null; then
            success "oneflow CLI"
        else
            if [[ -z "$SERVICE_ID" ]]; then
                warn "oneflow CLI not found — cluster auto-discovery unavailable"
                warn "Use --superlink IP:PORT or --skip-cluster to continue"
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

    # Discover via oneflow
    discover_via_oneflow
}

discover_via_oneflow() {
    info "Searching for Flower FL services..."

    local services_json
    services_json="$(oneflow list --json 2>/dev/null)" \
        || die "Failed to query OneFlow. Is the OpenNebula daemon running?"

    # Find services with "Flower" or "flower" in the name
    local service_ids
    mapfile -t service_ids < <(
        echo "$services_json" \
        | jq -r '.DOCUMENT_POOL.DOCUMENT[]
                  | select(.TEMPLATE.BODY.name | test("[Ff]lower"))
                  | .ID' 2>/dev/null
    )

    if [[ ${#service_ids[@]} -eq 0 ]]; then
        die "No Flower FL services found. Deploy a Flower service first, or use --superlink."
    fi

    # Pick a service
    local sid
    if [[ ${#service_ids[@]} -eq 1 ]]; then
        sid="${service_ids[0]}"
        info "Found Flower service: ID $sid"
    else
        # Build display names
        local display_names=()
        for id in "${service_ids[@]}"; do
            local name
            name="$(echo "$services_json" \
                | jq -r ".DOCUMENT_POOL.DOCUMENT[] | select(.ID == \"$id\") | .TEMPLATE.BODY.name")"
            display_names+=("$id — $name")
        done
        prompt_choice "Multiple Flower services found. Which one?" "${display_names[@]}"
        sid="${REPLY%% *}"
    fi

    # Allow --service-id override
    [[ -n "$SERVICE_ID" ]] && sid="$SERVICE_ID"

    info "Using service ID: $sid"

    # Wait for RUNNING state
    wait_for_service_running "$sid"

    # Extract SuperLink IP
    local show_json
    show_json="$(oneflow show "$sid" --json)"

    local superlink_ip
    superlink_ip="$(echo "$show_json" \
        | jq -r '.DOCUMENT.TEMPLATE.BODY.roles[]
                  | select(.name == "superlink")
                  | .nodes[0].vm_info.VM.TEMPLATE.NIC[0].IP' 2>/dev/null)"

    if [[ -z "$superlink_ip" || "$superlink_ip" == "null" ]]; then
        die "Could not extract SuperLink IP from service $sid"
    fi

    SUPERLINK="${superlink_ip}:${SUPERLINK_PORT}"
    success "SuperLink: $SUPERLINK"

    check_superlink_reachable "$superlink_ip" "$SUPERLINK_PORT"
}

wait_for_service_running() {
    local sid="$1"
    local elapsed=0

    while true; do
        local state
        state="$(oneflow show "$sid" --json \
            | jq -r '.DOCUMENT.TEMPLATE.BODY.state' 2>/dev/null)"

        if [[ "$state" == "$ONEFLOW_STATE_RUNNING" ]]; then
            success "Service $sid is RUNNING"
            return
        fi

        if [[ "$state" == "$ONEFLOW_STATE_DEPLOYING" ]]; then
            if (( elapsed >= DEPLOY_WAIT_MAX )); then
                die "Service $sid still deploying after ${DEPLOY_WAIT_MAX}s — check OneFlow logs"
            fi
            info "Service is deploying... waiting (${elapsed}s / ${DEPLOY_WAIT_MAX}s)"
            sleep "$DEPLOY_WAIT_INTERVAL"
            (( elapsed += DEPLOY_WAIT_INTERVAL ))
        else
            die "Service $sid is in unexpected state: $state (expected $ONEFLOW_STATE_RUNNING)"
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
        warn "Cannot reach ${host}:${port} — the cluster may still be starting, or a firewall is blocking access"
        if ! $AUTO; then
            prompt_yn "Continue anyway?" "y" || exit 1
        fi
    fi
}

# ── Stage 3: Framework selection ─────────────────────────────────────────────
select_framework() {
    stage 3 "Framework selection"

    # Discover available demos by looking for directories with pyproject.toml
    local demos=()
    local demo_base="$SCRIPT_DIR"

    for dir in "$demo_base"/*/; do
        [[ -f "${dir}pyproject.toml" ]] && demos+=("$(basename "$dir")")
    done

    if [[ ${#demos[@]} -eq 0 ]]; then
        die "No demo projects found in $demo_base/. Expected directories with pyproject.toml (e.g., pytorch/, tensorflow/, sklearn/)."
    fi

    prompt_choice "Which demo would you like to run?" "${demos[@]}"
    DEMO_DIR="$demo_base/$REPLY"

    success "Selected: $REPLY ($DEMO_DIR)"
}

# ── Stage 4: Python environment setup ────────────────────────────────────────
setup_venv() {
    stage 4 "Python environment"

    local venv_dir="$DEMO_DIR/.venv"

    if [[ -d "$venv_dir" ]]; then
        info "Existing venv found at $venv_dir"
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

    info "Installing dependencies (this may take a minute)..."
    pip install --upgrade pip --quiet
    pip install -e "$DEMO_DIR" --quiet \
        || die "pip install failed — check $DEMO_DIR/pyproject.toml"

    success "Dependencies installed"
}

# ── Stage 5: Configure federation ────────────────────────────────────────────
configure_federation() {
    stage 5 "Configure federation"

    local toml="$DEMO_DIR/pyproject.toml"

    if [[ ! -f "$toml" ]]; then
        die "pyproject.toml not found in $DEMO_DIR"
    fi

    if $SKIP_CLUSTER; then
        info "Skipping federation config (--skip-cluster)"
        return
    fi

    local sl_host="${SUPERLINK%%:*}"
    local sl_port="${SUPERLINK##*:}"
    local address="${sl_host}:${sl_port}"

    info "Patching SuperLink address in pyproject.toml..."

    # Patch the address field under the opennebula federation
    if grep -q 'address = ".*:'"$SUPERLINK_PORT"'"' "$toml"; then
        sed -i "s|address = \".*:${SUPERLINK_PORT}\"|address = \"${address}\"|" "$toml"
        success "Updated address → $address"
    elif grep -q '\[tool\.flwr\.federations\.opennebula\]' "$toml"; then
        # Section exists but no address line — add it after the section header
        sed -i "/\[tool\.flwr\.federations\.opennebula\]/a address = \"${address}\"" "$toml"
        success "Added address = \"$address\" to [tool.flwr.federations.opennebula]"
    else
        warn "Could not find [tool.flwr.federations.opennebula] in pyproject.toml"
        warn "You may need to set the SuperLink address manually: $address"
    fi

    # Show the relevant section for confirmation
    info "Federation config:"
    sed -n '/\[tool\.flwr\.federations\.opennebula\]/,/^\[/p' "$toml" | head -10
}

# ── Stage 6: Optional local simulation ──────────────────────────────────────
run_local_sim() {
    stage 6 "Local simulation"

    if ! prompt_yn "Run a local simulation first? (recommended to verify setup)" "y"; then
        info "Skipping local simulation"
        return
    fi

    info "Running local simulation..."
    echo -e "${DIM}"

    (cd "$DEMO_DIR" && flwr run . local-sim)
    local rc=$?

    echo -e "${RESET}"

    if [[ $rc -ne 0 ]]; then
        error "Local simulation failed (exit code $rc)"
        if $SKIP_CLUSTER; then
            die "Fix the errors above and try again"
        fi
        if ! prompt_yn "Continue to cluster run anyway?" "n"; then
            exit 1
        fi
    else
        success "Local simulation completed successfully"
    fi
}

# ── Stage 7: Run training on cluster ────────────────────────────────────────
run_on_cluster() {
    stage 7 "Run training on cluster"

    if $SKIP_CLUSTER; then
        info "Skipping cluster run (--skip-cluster)"
        return
    fi

    info "Starting federated training on the cluster..."
    info "SuperLink: $SUPERLINK"
    echo

    (cd "$DEMO_DIR" && flwr run . opennebula --stream)
    local rc=$?

    echo
    if [[ $rc -ne 0 ]]; then
        die "Training run failed (exit code $rc). Check the output above for errors."
    fi

    success "Training run completed"
}

# ── Stage 8: Next steps ─────────────────────────────────────────────────────
show_next_steps() {
    stage 8 "Done"

    echo
    if $SKIP_CLUSTER; then
        success "Local simulation completed successfully!"
        echo
        echo -e "${BOLD}Next steps:${RESET}"
        echo "  • Deploy a Flower FL cluster via OneFlow"
        echo "  • Re-run this script without --skip-cluster to train on the cluster"
    else
        success "Federated training completed!"
        echo
        echo -e "${BOLD}Cluster info:${RESET}"
        echo "  SuperLink: $SUPERLINK"
        echo "  Demo:      $(basename "$DEMO_DIR")"
        echo
        echo -e "${BOLD}Next steps:${RESET}"
        echo "  • Customize your strategy: edit $(basename "$DEMO_DIR")/pyproject.toml"
        echo "  • Use your own data: replace the dataset loader in the client code"
        echo "  • Adjust rounds: flwr run . opennebula --run-config \"num-server-rounds=10\""
        echo "  • Try a different strategy: --run-config \"strategy=FedProx\""
        echo "  • Monitor training: check SuperLink logs on the cluster"
    fi
    echo
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}Flower FL Quickstart for OpenNebula${RESET}"
    echo -e "${DIM}From deployed cluster to running training in minutes${RESET}"

    parse_args "$@"
    check_prerequisites
    discover_cluster
    select_framework
    setup_venv
    configure_federation
    run_local_sim
    run_on_cluster
    show_next_steps
}

main "$@"
