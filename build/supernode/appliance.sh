#!/usr/bin/env bash

# Flower SuperNode appliance lifecycle script for the one-apps framework.
# Implements APPL-02: SuperNode marketplace appliance with Docker-in-VM
# architecture, OneGate dynamic discovery, TLS trust, GPU passthrough,
# and DCGM monitoring sidecar.
#
# Spec references:
#   spec/02-supernode-appliance.md  -- boot sequence, discovery, health check
#   spec/03-contextualization-reference.md -- variable definitions
#   spec/05-supernode-tls-trust.md  -- CA cert retrieval
#   spec/10-gpu-passthrough.md      -- GPU detection and fallback
#   spec/13-monitoring-observability.md -- DCGM exporter sidecar

### Flower SuperNode Configuration ############################################

FLOWER_DIR="/opt/flower"
FLOWER_SCRIPTS_DIR="${FLOWER_DIR}/scripts"
FLOWER_CONFIG_DIR="${FLOWER_DIR}/config"
FLOWER_CERTS_DIR="${FLOWER_DIR}/certs"
FLOWER_DATA_DIR="${FLOWER_DIR}/data"
FLOWER_CONTAINER="flower-supernode"
DCGM_CONTAINER="dcgm-exporter"
PREBAKED_VERSION="1.25.0"
ONE_SERVICE_SETUP_DIR="/opt/one-appliance"

### Appliance Metadata ########################################################

ONE_SERVICE_NAME='Service Flower SuperNode - KVM'
ONE_SERVICE_VERSION='1.0.0'
ONE_SERVICE_BUILD=$(date +%s)
ONE_SERVICE_SHORT_DESCRIPTION='Flower Federated Learning SuperNode appliance'
ONE_SERVICE_DESCRIPTION=$(cat <<'EOF'
Flower SuperNode appliance for privacy-preserving federated learning on
OpenNebula infrastructure. Each SuperNode trains a local model partition
and communicates weight updates to the SuperLink coordinator. Data never
leaves the VM.

Features:
- Zero-config deployment via OneGate dynamic SuperLink discovery
- Static SuperLink address override for cross-site federation
- TLS trust with automatic CA certificate retrieval from OneGate
- GPU passthrough with graceful CPU fallback
- DCGM GPU metrics exporter sidecar (optional)
- Exponential backoff discovery for edge deployments

After deploying, check /etc/one-appliance/status for boot progress.
Logs are in /var/log/one-appliance/.

NOTE: This appliance is immutable. To change configuration, redeploy
with updated context variables.
EOF
)

ONE_SERVICE_RECONFIGURABLE=true

### CONTEXT SECTION ###########################################################

ONE_SERVICE_PARAMS=(
    # Phase 1: Base architecture
    'ONEAPP_FLOWER_VERSION'            'configure' 'Flower Docker image version tag'                            '1.25.0'
    'ONEAPP_FL_SUPERLINK_ADDRESS'      'configure' 'SuperLink Fleet API address (host:port)'                    ''
    'ONEAPP_FL_NODE_CONFIG'            'configure' 'Space-separated key=value node config'                      ''
    'ONEAPP_FL_MAX_RETRIES'            'configure' 'Max reconnection attempts (0=unlimited)'                    '0'
    'ONEAPP_FL_MAX_WAIT_TIME'          'configure' 'Max wait time for connection in seconds (0=unlimited)'      '0'
    'ONEAPP_FL_ISOLATION'              'configure' 'App execution isolation mode (subprocess|process)'          'subprocess'
    'ONEAPP_FL_LOG_LEVEL'              'configure' 'Log verbosity (DEBUG|INFO|WARNING|ERROR)'                   'INFO'
    # Phase 2: TLS
    'ONEAPP_FL_TLS_ENABLED'            'configure' 'Enable TLS encryption (YES|NO)'                             'NO'
    # Phase 6: GPU
    'ONEAPP_FL_GPU_ENABLED'            'configure' 'Enable GPU passthrough (YES|NO)'                            'NO'
    'ONEAPP_FL_CUDA_VISIBLE_DEVICES'   'configure' 'GPU device IDs visible to container'                        'all'
    'ONEAPP_FL_GPU_MEMORY_FRACTION'    'configure' 'GPU memory fraction for PyTorch (0.0-1.0)'                  '0.8'
    # Phase 7: Multi-site federation
    'ONEAPP_FL_GRPC_KEEPALIVE_TIME'    'configure' 'gRPC keepalive interval in seconds'                         '60'
    'ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT' 'configure' 'gRPC keepalive ACK timeout in seconds'                      '20'
    # Phase 8: Monitoring
    'ONEAPP_FL_LOG_FORMAT'             'configure' 'Log output format (text|json)'                              'text'
    'ONEAPP_FL_DCGM_ENABLED'           'configure' 'Enable DCGM GPU metrics exporter (YES|NO)'                  'NO'
    # Phase 9: Edge
    'ONEAPP_FL_EDGE_BACKOFF'           'configure' 'Edge discovery retry backoff (exponential|fixed)'           'exponential'
    'ONEAPP_FL_EDGE_MAX_BACKOFF'       'configure' 'Maximum backoff interval in seconds for edge discovery'     '300'
)

### Default Value Assignments #################################################

ONEAPP_FLOWER_VERSION="${ONEAPP_FLOWER_VERSION:-1.25.0}"
ONEAPP_FL_SUPERLINK_ADDRESS="${ONEAPP_FL_SUPERLINK_ADDRESS:-}"
ONEAPP_FL_NODE_CONFIG="${ONEAPP_FL_NODE_CONFIG:-}"
ONEAPP_FL_MAX_RETRIES="${ONEAPP_FL_MAX_RETRIES:-0}"
ONEAPP_FL_MAX_WAIT_TIME="${ONEAPP_FL_MAX_WAIT_TIME:-0}"
ONEAPP_FL_ISOLATION="${ONEAPP_FL_ISOLATION:-subprocess}"
ONEAPP_FL_LOG_LEVEL="${ONEAPP_FL_LOG_LEVEL:-INFO}"
ONEAPP_FL_TLS_ENABLED="${ONEAPP_FL_TLS_ENABLED:-NO}"
ONEAPP_FL_LOG_FORMAT="${ONEAPP_FL_LOG_FORMAT:-text}"
ONEAPP_FL_GPU_ENABLED="${ONEAPP_FL_GPU_ENABLED:-NO}"
ONEAPP_FL_CUDA_VISIBLE_DEVICES="${ONEAPP_FL_CUDA_VISIBLE_DEVICES:-all}"
ONEAPP_FL_GPU_MEMORY_FRACTION="${ONEAPP_FL_GPU_MEMORY_FRACTION:-0.8}"
ONEAPP_FL_GRPC_KEEPALIVE_TIME="${ONEAPP_FL_GRPC_KEEPALIVE_TIME:-60}"
ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT="${ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT:-20}"
ONEAPP_FL_DCGM_ENABLED="${ONEAPP_FL_DCGM_ENABLED:-NO}"
ONEAPP_FL_EDGE_BACKOFF="${ONEAPP_FL_EDGE_BACKOFF:-exponential}"
ONEAPP_FL_EDGE_MAX_BACKOFF="${ONEAPP_FL_EDGE_MAX_BACKOFF:-300}"

###############################################################################
# Mandatory lifecycle functions -- called by the one-apps service manager
###############################################################################

# service_install: runs once during Packer image build.
# Installs Docker CE, pre-pulls the Flower SuperNode image, installs jq,
# creates the /opt/flower directory tree, and optionally installs the
# NVIDIA Container Toolkit if GPU hardware is detected on the build host.
service_install()
{
    mkdir -p "$ONE_SERVICE_SETUP_DIR"

    msg info "Installing Docker CE"
    install_docker

    msg info "Installing jq for JSON parsing"
    if ! apt-get install -y jq curl netcat-openbsd; then
        msg error "Failed to install jq/curl/netcat"
        exit 1
    fi

    msg info "Pre-pulling Flower SuperNode image flwr/supernode:${PREBAKED_VERSION}"
    if ! docker pull "flwr/supernode:${PREBAKED_VERSION}"; then
        msg error "Failed to pull flwr/supernode:${PREBAKED_VERSION}"
        exit 1
    fi

    msg info "Installing NVIDIA Container Toolkit (best-effort)"
    install_nvidia_ctk || msg warning "NVIDIA CTK install skipped -- no GPU detected or repo unavailable"

    msg info "Creating /opt/flower directory structure"
    mkdir -p "${FLOWER_SCRIPTS_DIR}" "${FLOWER_CONFIG_DIR}" "${FLOWER_DATA_DIR}" "${FLOWER_CERTS_DIR}"
    chown -R 49999:49999 "${FLOWER_DATA_DIR}" "${FLOWER_CERTS_DIR}"

    msg info "Writing prebaked version marker"
    echo "${PREBAKED_VERSION}" > "${FLOWER_DIR}/PREBAKED_VERSION"

    msg info "Cleaning apt cache"
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    msg info "INSTALLATION FINISHED"
    return 0
}

# service_configure: runs at each VM boot.
# Reads context variables, validates them, discovers SuperLink (static or
# OneGate), sets up TLS trust if enabled, generates the systemd unit and
# env file, and auto-computes partition ID when FL_NODE_CONFIG is empty.
service_configure()
{
    msg info "--- SuperNode configure stage ---"

    # Step 2: source one-context environment
    if [ -f /run/one-context/one_env ]; then
        # shellcheck disable=SC1091
        . /run/one-context/one_env
    fi

    # Step 3: validate configuration
    validate_config || exit 1

    # Step 4: create mount dirs with correct ownership
    mkdir -p "${FLOWER_DATA_DIR}" "${FLOWER_CERTS_DIR}" "${FLOWER_CONFIG_DIR}"
    chown -R 49999:49999 "${FLOWER_DATA_DIR}" "${FLOWER_CERTS_DIR}"

    # Step 7: SuperLink discovery
    SUPERLINK_ADDRESS=""
    if [ -n "${ONEAPP_FL_SUPERLINK_ADDRESS}" ]; then
        msg info "Using static SuperLink address: ${ONEAPP_FL_SUPERLINK_ADDRESS}"
        SUPERLINK_ADDRESS="${ONEAPP_FL_SUPERLINK_ADDRESS}"
    else
        msg info "No static address set; attempting OneGate discovery"
        SUPERLINK_ADDRESS=$(discover_superlink)
        if [ -z "${SUPERLINK_ADDRESS}" ]; then
            msg error "SuperLink discovery failed"
            exit 1
        fi
    fi

    # TLS setup: determine mode and retrieve CA cert if needed
    TLS_MODE="disabled"
    setup_tls_trust
    msg info "TLS mode: ${TLS_MODE}"

    # Auto-compute partition ID if FL_NODE_CONFIG is empty
    if [ -z "${ONEAPP_FL_NODE_CONFIG}" ]; then
        compute_partition_id
    fi

    # Determine container image version
    VERSION="${ONEAPP_FLOWER_VERSION}"

    # Build TLS-related Docker flags
    TLS_FLAGS="--insecure"
    TLS_VOLUME_FLAGS=""
    if [ "${TLS_MODE}" = "enabled" ]; then
        TLS_FLAGS="--root-certificates /app/ca.crt"
        TLS_VOLUME_FLAGS="-v ${FLOWER_CERTS_DIR}/ca.crt:/app/ca.crt:ro"
    fi

    # Step 5: generate supernode.env
    generate_env_file

    # Step 6: generate systemd unit
    generate_systemd_unit

    # Write service report
    cat > "${ONE_SERVICE_REPORT:-/etc/one-appliance/config}" <<EOF
[Flower SuperNode]
superlink = ${SUPERLINK_ADDRESS}
version   = ${VERSION}
isolation = ${ONEAPP_FL_ISOLATION}
tls       = ${TLS_MODE}
gpu       = ${ONEAPP_FL_GPU_ENABLED}
EOF
    chmod 600 "${ONE_SERVICE_REPORT:-/etc/one-appliance/config}" 2>/dev/null

    msg info "CONFIGURATION FINISHED"
    return 0
}

# service_bootstrap: runs after configure, starts the container.
# Waits for Docker, detects GPU, handles version overrides, starts the
# systemd service, waits for health, publishes to OneGate, and optionally
# starts the DCGM exporter sidecar.
service_bootstrap()
{
    msg info "--- SuperNode bootstrap stage ---"

    # Step 8: wait for Docker daemon
    wait_for_docker || { msg error "Docker daemon not available"; exit 1; }

    # Step 9: GPU detection
    DOCKER_GPU_FLAGS=""
    DOCKER_ENV_FLAGS=""
    FL_GPU_AVAILABLE="NO"
    detect_gpu

    # Step 10: handle version override
    if [ "${VERSION}" != "${PREBAKED_VERSION}" ]; then
        msg info "Requested version ${VERSION} differs from prebaked ${PREBAKED_VERSION}; pulling..."
        if ! docker pull "flwr/supernode:${VERSION}" 2>/dev/null; then
            msg warning "Pull failed for flwr/supernode:${VERSION}; using prebaked ${PREBAKED_VERSION}"
            VERSION="${PREBAKED_VERSION}"
        fi
    fi

    # Create the container (Step 11 prep -- container creation separate from systemd start)
    docker rm -f "${FLOWER_CONTAINER}" 2>/dev/null || true

    # Build the full docker create command
    local create_cmd="docker create --name ${FLOWER_CONTAINER} --restart unless-stopped"
    create_cmd+=" ${DOCKER_GPU_FLAGS}"
    create_cmd+=" ${DOCKER_ENV_FLAGS}"
    create_cmd+=" -v ${FLOWER_DATA_DIR}:/app/data:ro"
    create_cmd+=" ${TLS_VOLUME_FLAGS}"
    create_cmd+=" --env-file ${FLOWER_CONFIG_DIR}/supernode.env"
    create_cmd+=" flwr/supernode:${VERSION}"
    create_cmd+=" ${TLS_FLAGS}"
    create_cmd+=" --superlink ${SUPERLINK_ADDRESS}"
    create_cmd+=" --isolation ${ONEAPP_FL_ISOLATION}"
    create_cmd+=" --node-config \"${ONEAPP_FL_NODE_CONFIG}\""
    create_cmd+=" --max-retries ${ONEAPP_FL_MAX_RETRIES}"
    create_cmd+=" --max-wait-time ${ONEAPP_FL_MAX_WAIT_TIME}"

    msg info "Creating container: ${create_cmd}"
    eval "${create_cmd}" || { msg error "Failed to create container"; exit 1; }

    # Step 11: start via systemd
    systemctl daemon-reload
    systemctl enable flower-supernode.service
    systemctl start flower-supernode.service

    # Step 12: wait for container running state
    wait_for_container || { msg error "Container failed to reach running state"; exit 1; }

    # Step 13: publish to OneGate (best-effort)
    publish_to_onegate "FL_NODE_READY" "YES"
    publish_to_onegate "FL_NODE_ID" "${VMID:-unknown}"
    publish_to_onegate "FL_VERSION" "${VERSION}"
    publish_to_onegate "FL_GPU_AVAILABLE" "${FL_GPU_AVAILABLE}"

    # Step 14a: start DCGM exporter sidecar if requested
    if [ "${ONEAPP_FL_DCGM_ENABLED}" = "YES" ] && \
       [ "${ONEAPP_FL_GPU_ENABLED}" = "YES" ] && \
       [ "${FL_GPU_AVAILABLE}" = "YES" ]; then
        start_dcgm_exporter
    fi

    msg info "BOOTSTRAP FINISHED"
    return 0
}

service_help()
{
    msg info "Flower SuperNode appliance -- Federated Learning client node"
    msg info ""
    msg info "Context variables:"
    msg info "  ONEAPP_FLOWER_VERSION            Flower version (default: 1.25.0)"
    msg info "  ONEAPP_FL_SUPERLINK_ADDRESS      Static SuperLink address (host:port)"
    msg info "  ONEAPP_FL_NODE_CONFIG            key=value pairs for ClientApp"
    msg info "  ONEAPP_FL_GPU_ENABLED            Enable GPU passthrough (YES/NO)"
    msg info "  ONEAPP_FL_TLS_ENABLED            Enable TLS encryption (YES/NO)"
    msg info ""
    msg info "Logs: /var/log/one-appliance/"
    msg info "Container logs: docker logs flower-supernode"
    return 0
}

service_cleanup()
{
    msg info "Cleaning up Flower SuperNode"
    docker rm -f "${FLOWER_CONTAINER}" 2>/dev/null || true
    docker rm -f "${DCGM_CONTAINER}" 2>/dev/null || true
    return 0
}

###############################################################################
# Helper Functions
###############################################################################

# install_docker: Install Docker CE from the official apt repository.
install_docker()
{
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin; then
        msg error "Failed to install Docker CE"
        exit 1
    fi

    systemctl enable docker
    msg info "Docker CE installed"
}

# install_nvidia_ctk: Best-effort install of the NVIDIA Container Toolkit.
# Skips silently if no GPU is detected on the build host.
install_nvidia_ctk()
{
    # Only attempt if nvidia-smi is present on the build host
    if ! command -v nvidia-smi &>/dev/null && ! lsmod 2>/dev/null | grep -q nvidia; then
        return 1
    fi

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update
    apt-get install -y nvidia-container-toolkit || return 1
    nvidia-ctk runtime configure --runtime=docker || return 1
    msg info "NVIDIA Container Toolkit installed"
}

# validate_config: Fail-fast validation of all context variables.
# Collects all errors before aborting so operators can fix them in one pass.
validate_config()
{
    local errors=0

    # FLOWER_VERSION: semver format
    if [ -n "${ONEAPP_FLOWER_VERSION}" ] && \
       ! [[ "${ONEAPP_FLOWER_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        msg error "Invalid ONEAPP_FLOWER_VERSION: '${ONEAPP_FLOWER_VERSION}'. Expected format: X.Y.Z"
        errors=$((errors + 1))
    fi

    # FL_SUPERLINK_ADDRESS: host:port if set
    if [ -n "${ONEAPP_FL_SUPERLINK_ADDRESS}" ] && \
       ! [[ "${ONEAPP_FL_SUPERLINK_ADDRESS}" =~ ^[^:]+:[0-9]+$ ]]; then
        msg error "Invalid ONEAPP_FL_SUPERLINK_ADDRESS: '${ONEAPP_FL_SUPERLINK_ADDRESS}'. Expected host:port"
        errors=$((errors + 1))
    fi

    # FL_MAX_RETRIES: non-negative integer
    if ! [[ "${ONEAPP_FL_MAX_RETRIES}" =~ ^[0-9]+$ ]]; then
        msg error "Invalid ONEAPP_FL_MAX_RETRIES: '${ONEAPP_FL_MAX_RETRIES}'. Must be a non-negative integer"
        errors=$((errors + 1))
    fi

    # FL_MAX_WAIT_TIME: non-negative integer
    if ! [[ "${ONEAPP_FL_MAX_WAIT_TIME}" =~ ^[0-9]+$ ]]; then
        msg error "Invalid ONEAPP_FL_MAX_WAIT_TIME: '${ONEAPP_FL_MAX_WAIT_TIME}'. Must be a non-negative integer"
        errors=$((errors + 1))
    fi

    # FL_ISOLATION: enum
    case "${ONEAPP_FL_ISOLATION}" in
        subprocess|process) ;;
        *) msg error "Invalid ONEAPP_FL_ISOLATION: '${ONEAPP_FL_ISOLATION}'. Must be subprocess or process"
           errors=$((errors + 1)) ;;
    esac

    # FL_LOG_LEVEL: enum
    case "${ONEAPP_FL_LOG_LEVEL}" in
        DEBUG|INFO|WARNING|ERROR) ;;
        *) msg error "Invalid ONEAPP_FL_LOG_LEVEL: '${ONEAPP_FL_LOG_LEVEL}'. Must be DEBUG, INFO, WARNING, or ERROR"
           errors=$((errors + 1)) ;;
    esac

    # FL_TLS_ENABLED: boolean
    case "${ONEAPP_FL_TLS_ENABLED}" in
        YES|NO) ;;
        *) msg error "Invalid ONEAPP_FL_TLS_ENABLED: '${ONEAPP_FL_TLS_ENABLED}'. Must be YES or NO"
           errors=$((errors + 1)) ;;
    esac

    # FL_LOG_FORMAT: enum
    case "${ONEAPP_FL_LOG_FORMAT}" in
        text|json) ;;
        *) msg error "Invalid ONEAPP_FL_LOG_FORMAT: '${ONEAPP_FL_LOG_FORMAT}'. Must be text or json"
           errors=$((errors + 1)) ;;
    esac

    # FL_GPU_ENABLED: boolean
    case "${ONEAPP_FL_GPU_ENABLED}" in
        YES|NO) ;;
        *) msg error "Invalid ONEAPP_FL_GPU_ENABLED: '${ONEAPP_FL_GPU_ENABLED}'. Must be YES or NO"
           errors=$((errors + 1)) ;;
    esac

    # FL_CUDA_VISIBLE_DEVICES: 'all' or comma-separated integers
    if [ "${ONEAPP_FL_CUDA_VISIBLE_DEVICES}" != "all" ] && \
       ! [[ "${ONEAPP_FL_CUDA_VISIBLE_DEVICES}" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        msg error "Invalid ONEAPP_FL_CUDA_VISIBLE_DEVICES: '${ONEAPP_FL_CUDA_VISIBLE_DEVICES}'. Must be 'all' or comma-separated GPU IDs"
        errors=$((errors + 1))
    fi

    # FL_GRPC_KEEPALIVE_TIME: positive integer
    if ! [[ "${ONEAPP_FL_GRPC_KEEPALIVE_TIME}" =~ ^[1-9][0-9]*$ ]]; then
        msg error "Invalid ONEAPP_FL_GRPC_KEEPALIVE_TIME: '${ONEAPP_FL_GRPC_KEEPALIVE_TIME}'. Must be a positive integer"
        errors=$((errors + 1))
    fi

    # FL_GRPC_KEEPALIVE_TIMEOUT: positive integer, less than keepalive_time
    if ! [[ "${ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]]; then
        msg error "Invalid ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT: '${ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT}'. Must be a positive integer"
        errors=$((errors + 1))
    elif [ "${ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT}" -ge "${ONEAPP_FL_GRPC_KEEPALIVE_TIME}" ] 2>/dev/null; then
        msg error "ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT (${ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT}) must be < ONEAPP_FL_GRPC_KEEPALIVE_TIME (${ONEAPP_FL_GRPC_KEEPALIVE_TIME})"
        errors=$((errors + 1))
    fi

    # FL_DCGM_ENABLED: boolean
    case "${ONEAPP_FL_DCGM_ENABLED}" in
        YES|NO) ;;
        *) msg error "Invalid ONEAPP_FL_DCGM_ENABLED: '${ONEAPP_FL_DCGM_ENABLED}'. Must be YES or NO"
           errors=$((errors + 1)) ;;
    esac

    # FL_EDGE_BACKOFF: enum
    case "${ONEAPP_FL_EDGE_BACKOFF}" in
        exponential|fixed) ;;
        *) msg error "Invalid ONEAPP_FL_EDGE_BACKOFF: '${ONEAPP_FL_EDGE_BACKOFF}'. Must be exponential or fixed"
           errors=$((errors + 1)) ;;
    esac

    # FL_EDGE_MAX_BACKOFF: positive integer
    if ! [[ "${ONEAPP_FL_EDGE_MAX_BACKOFF}" =~ ^[1-9][0-9]*$ ]]; then
        msg error "Invalid ONEAPP_FL_EDGE_MAX_BACKOFF: '${ONEAPP_FL_EDGE_MAX_BACKOFF}'. Must be a positive integer"
        errors=$((errors + 1))
    fi

    # Cross-check warnings (non-fatal)
    if [ "${ONEAPP_FL_DCGM_ENABLED}" = "YES" ] && [ "${ONEAPP_FL_GPU_ENABLED}" != "YES" ]; then
        msg warning "ONEAPP_FL_DCGM_ENABLED=YES but ONEAPP_FL_GPU_ENABLED is not YES; DCGM will not start"
    fi
    if [ "${ONEAPP_FL_GRPC_KEEPALIVE_TIME}" -lt 10 ] 2>/dev/null; then
        msg warning "ONEAPP_FL_GRPC_KEEPALIVE_TIME=${ONEAPP_FL_GRPC_KEEPALIVE_TIME} is aggressive; may cause excessive network traffic"
    fi

    if [ "${errors}" -gt 0 ]; then
        msg error "${errors} configuration error(s). Aborting boot."
        return 1
    fi

    msg info "Configuration validation passed"
    return 0
}

# discover_superlink: Resolve the SuperLink Fleet API address via OneGate.
# Implements the retry loop from spec/02 Section 6d with edge backoff support.
# Outputs the discovered address on stdout; returns non-zero on failure.
discover_superlink()
{
    # Read OneGate environment
    local onegate_endpoint="${ONEGATE_ENDPOINT:-}"
    local onegate_token=""
    local vmid="${VMID:-}"

    if [ -f /run/one-context/token.txt ]; then
        onegate_token=$(cat /run/one-context/token.txt)
    fi

    if [ -z "${onegate_endpoint}" ] || [ -z "${onegate_token}" ]; then
        msg error "OneGate not available (no ONEGATE_ENDPOINT or token). Set ONEAPP_FL_SUPERLINK_ADDRESS for static mode."
        return 1
    fi

    # Connectivity pre-check (spec/02 Section 6e)
    local pre_status
    pre_status=$(curl -s -o /dev/null -w "%{http_code}" "${onegate_endpoint}/vm" \
        -H "X-ONEGATE-TOKEN: ${onegate_token}" \
        -H "X-ONEGATE-VMID: ${vmid}" 2>/dev/null)

    if [ "${pre_status}" -lt 200 ] || [ "${pre_status}" -ge 400 ] 2>/dev/null; then
        msg error "OneGate unreachable at ${onegate_endpoint} (HTTP ${pre_status})"
        return 1
    fi
    msg info "OneGate connectivity verified"

    # Retry loop: 30 attempts at 10s interval (fixed mode) or exponential backoff
    local max_retries=30
    local interval=10
    local attempt=1
    local fl_endpoint=""

    while [ "${attempt}" -le "${max_retries}" ] || [ "${ONEAPP_FL_EDGE_BACKOFF}" = "exponential" ]; do
        local service_json
        service_json=$(curl -s "${onegate_endpoint}/service" \
            -H "X-ONEGATE-TOKEN: ${onegate_token}" \
            -H "X-ONEGATE-VMID: ${vmid}" 2>/dev/null)

        fl_endpoint=$(echo "${service_json}" | jq -r '
            .SERVICE.roles[]
            | select(.name == "superlink")
            | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_ENDPOINT // empty
        ' 2>/dev/null)

        if [ -n "${fl_endpoint}" ]; then
            msg info "Discovered SuperLink at ${fl_endpoint} (attempt ${attempt})"
            echo "${fl_endpoint}"
            return 0
        fi

        # Fixed mode: bounded retries
        if [ "${ONEAPP_FL_EDGE_BACKOFF}" = "fixed" ] && [ "${attempt}" -ge "${max_retries}" ]; then
            break
        fi

        # Exponential mode: unbounded retries with increasing backoff
        if [ "${ONEAPP_FL_EDGE_BACKOFF}" = "exponential" ]; then
            interval=$((interval * 2))
            if [ "${interval}" -gt "${ONEAPP_FL_EDGE_MAX_BACKOFF}" ]; then
                interval="${ONEAPP_FL_EDGE_MAX_BACKOFF}"
            fi
        fi

        msg info "SuperLink not ready, waiting ${interval}s... (attempt ${attempt})"
        sleep "${interval}"
        attempt=$((attempt + 1))
    done

    msg error "SuperLink discovery timed out after ${attempt} attempts"
    return 1
}

# detect_gpu: Check GPU availability when ONEAPP_FL_GPU_ENABLED=YES.
# Sets DOCKER_GPU_FLAGS, DOCKER_ENV_FLAGS, and FL_GPU_AVAILABLE.
detect_gpu()
{
    if [ "${ONEAPP_FL_GPU_ENABLED}" != "YES" ]; then
        DOCKER_GPU_FLAGS=""
        FL_GPU_AVAILABLE="NO"
        return 0
    fi

    if lsmod | grep -q nvidia && nvidia-smi >/dev/null 2>&1; then
        DOCKER_GPU_FLAGS="--gpus all"
        FL_GPU_AVAILABLE="YES"

        if [ "${ONEAPP_FL_CUDA_VISIBLE_DEVICES}" != "all" ]; then
            DOCKER_ENV_FLAGS="-e CUDA_VISIBLE_DEVICES=${ONEAPP_FL_CUDA_VISIBLE_DEVICES}"
        fi

        msg info "GPU detected; container will launch with GPU access"
    else
        DOCKER_GPU_FLAGS=""
        FL_GPU_AVAILABLE="NO"
        msg warning "ONEAPP_FL_GPU_ENABLED=YES but GPU not available (nvidia-smi failed or module not loaded)"
        msg warning "Falling back to CPU-only training"
    fi
}

# setup_tls_trust: Determine TLS mode and retrieve CA certificate if needed.
# Priority: explicit CONTEXT > OneGate auto-detect > insecure default.
# Sets the global TLS_MODE variable to 'enabled' or 'disabled'.
setup_tls_trust()
{
    # Priority 1: explicit CONTEXT variable
    if [ "${ONEAPP_FL_TLS_ENABLED}" = "YES" ]; then
        msg info "TLS explicitly enabled via ONEAPP_FL_TLS_ENABLED=YES"
        retrieve_ca_cert
        TLS_MODE="enabled"
        return 0
    fi

    # Priority 2: if TLS explicitly disabled, respect operator intent
    if [ "${ONEAPP_FL_TLS_ENABLED}" = "NO" ]; then
        # Still check OneGate for FL_TLS flag to log a warning
        if [ -n "${ONEGATE_ENDPOINT:-}" ] && [ -z "${ONEAPP_FL_SUPERLINK_ADDRESS}" ]; then
            local onegate_token=""
            [ -f /run/one-context/token.txt ] && onegate_token=$(cat /run/one-context/token.txt)

            if [ -n "${onegate_token}" ]; then
                local service_json
                service_json=$(curl -s "${ONEGATE_ENDPOINT}/service" \
                    -H "X-ONEGATE-TOKEN: ${onegate_token}" \
                    -H "X-ONEGATE-VMID: ${VMID:-}" 2>/dev/null)

                local tls_flag
                tls_flag=$(echo "${service_json}" | jq -r '
                    .SERVICE.roles[]
                    | select(.name == "superlink")
                    | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_TLS // empty
                ' 2>/dev/null)

                if [ "${tls_flag}" = "YES" ]; then
                    msg warning "SuperLink advertises FL_TLS=YES but ONEAPP_FL_TLS_ENABLED=NO; using insecure mode per operator intent"
                fi
            fi
        fi
        TLS_MODE="disabled"
        return 0
    fi
}

# retrieve_ca_cert: Obtain and validate the CA certificate for TLS trust.
# Tries OneGate FL_CA_CERT first, falls back to FL_SSL_CA_CERTFILE context var.
retrieve_ca_cert()
{
    local cert_path="${FLOWER_CERTS_DIR}/ca.crt"

    # Path A: operator-provided CA via CONTEXT (FL_SSL_CA_CERTFILE base64)
    if [ -n "${ONEAPP_FL_SSL_CA_CERTFILE:-}" ]; then
        msg info "Using operator-provided CA certificate from CONTEXT"
        echo "${ONEAPP_FL_SSL_CA_CERTFILE}" | base64 -d > "${cert_path}" 2>/dev/null
        finalize_ca_cert "${cert_path}"
        return $?
    fi

    # Path B: retrieve from OneGate (FL_CA_CERT on SuperLink VM)
    if [ -n "${ONEGATE_ENDPOINT:-}" ]; then
        local onegate_token=""
        [ -f /run/one-context/token.txt ] && onegate_token=$(cat /run/one-context/token.txt)

        if [ -n "${onegate_token}" ]; then
            local service_json
            service_json=$(curl -s "${ONEGATE_ENDPOINT}/service" \
                -H "X-ONEGATE-TOKEN: ${onegate_token}" \
                -H "X-ONEGATE-VMID: ${VMID:-}" 2>/dev/null)

            local ca_b64
            ca_b64=$(echo "${service_json}" | jq -r '
                .SERVICE.roles[]
                | select(.name == "superlink")
                | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_CA_CERT // empty
            ' 2>/dev/null)

            if [ -n "${ca_b64}" ]; then
                msg info "CA certificate retrieved from OneGate"
                echo "${ca_b64}" | base64 -d > "${cert_path}" 2>/dev/null
                finalize_ca_cert "${cert_path}"
                return $?
            fi
        fi
    fi

    msg error "TLS enabled but no CA certificate available (set FL_SSL_CA_CERTFILE or ensure SuperLink publishes FL_CA_CERT)"
    exit 1
}

# finalize_ca_cert: Set ownership, permissions, and validate the PEM file.
finalize_ca_cert()
{
    local cert_path="$1"
    chown 49999:49999 "${cert_path}"
    chmod 0644 "${cert_path}"

    if ! openssl x509 -in "${cert_path}" -noout 2>/dev/null; then
        msg error "Invalid CA certificate at ${cert_path}"
        exit 1
    fi
    msg info "CA certificate validated: ${cert_path}"
}

# compute_partition_id: Auto-compute partition-id from OneGate service info.
# Sets ONEAPP_FL_NODE_CONFIG when empty, using the VM's index in the
# supernode role's nodes array.
compute_partition_id()
{
    if [ -z "${ONEGATE_ENDPOINT:-}" ]; then
        msg info "OneGate not available; skipping auto partition-id computation"
        return 0
    fi

    local onegate_token=""
    [ -f /run/one-context/token.txt ] && onegate_token=$(cat /run/one-context/token.txt)
    [ -z "${onegate_token}" ] && return 0

    local service_json
    service_json=$(curl -s "${ONEGATE_ENDPOINT}/service" \
        -H "X-ONEGATE-TOKEN: ${onegate_token}" \
        -H "X-ONEGATE-VMID: ${VMID:-}" 2>/dev/null)

    local nodes num_partitions my_index
    nodes=$(echo "${service_json}" | jq '.SERVICE.roles[] | select(.name == "supernode") | .nodes' 2>/dev/null)

    if [ -z "${nodes}" ] || [ "${nodes}" = "null" ]; then
        msg warning "Could not read supernode role nodes from OneGate; partition-id not set"
        return 0
    fi

    num_partitions=$(echo "${nodes}" | jq 'length' 2>/dev/null)
    my_index=$(echo "${nodes}" | jq --arg vmid "${VMID:-}" \
        '[.[].deploy_id | tostring] | to_entries[] | select(.value == $vmid) | .key' 2>/dev/null)

    if [ -n "${my_index}" ] && [ -n "${num_partitions}" ]; then
        ONEAPP_FL_NODE_CONFIG="partition-id=${my_index} num-partitions=${num_partitions}"
        msg info "Auto-computed node config: ${ONEAPP_FL_NODE_CONFIG}"
    else
        msg warning "Could not determine VM index in supernode role; partition-id not set"
    fi
}

# generate_env_file: Write the Docker environment file for the container.
generate_env_file()
{
    cat > "${FLOWER_CONFIG_DIR}/supernode.env" <<EOF
FLWR_LOG_LEVEL=${ONEAPP_FL_LOG_LEVEL}
EOF

    # GPU memory fraction passed as env var for PyTorch framework variant
    if [ "${ONEAPP_FL_GPU_ENABLED}" = "YES" ]; then
        echo "FL_GPU_MEMORY_FRACTION=${ONEAPP_FL_GPU_MEMORY_FRACTION}" \
            >> "${FLOWER_CONFIG_DIR}/supernode.env"
    fi

    chmod 600 "${FLOWER_CONFIG_DIR}/supernode.env"
    msg info "Generated ${FLOWER_CONFIG_DIR}/supernode.env"
}

# generate_systemd_unit: Write the flower-supernode.service unit file.
# The container is pre-created during bootstrap; systemd manages start/stop.
generate_systemd_unit()
{
    cat > /etc/systemd/system/flower-supernode.service <<'EOF'
[Unit]
Description=Flower SuperNode (Federated Learning Client)
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
ExecStartPre=-/usr/bin/docker rm -f flower-supernode
ExecStart=/usr/bin/docker start -a flower-supernode
ExecStop=/usr/bin/docker stop -t 30 flower-supernode

[Install]
WantedBy=multi-user.target
EOF

    msg info "Generated /etc/systemd/system/flower-supernode.service"
}

# wait_for_docker: Poll docker info until the daemon is ready (60s timeout).
wait_for_docker()
{
    local timeout=60
    local elapsed=0

    while ! docker info >/dev/null 2>&1; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "${elapsed}" -ge "${timeout}" ]; then
            msg error "Docker daemon not ready after ${timeout}s"
            return 1
        fi
    done

    msg info "Docker daemon ready (${elapsed}s)"
    return 0
}

# wait_for_container: Poll container running state (60s timeout).
wait_for_container()
{
    local timeout=60
    local elapsed=0

    while true; do
        local running
        running=$(docker inspect --format='{{.State.Running}}' "${FLOWER_CONTAINER}" 2>/dev/null)

        if [ "${running}" = "true" ]; then
            msg info "Container ${FLOWER_CONTAINER} is running (${elapsed}s)"
            return 0
        fi

        sleep 1
        elapsed=$((elapsed + 1))
        if [ "${elapsed}" -ge "${timeout}" ]; then
            msg error "Container ${FLOWER_CONTAINER} not running after ${timeout}s"
            docker logs "${FLOWER_CONTAINER}" 2>&1 | tail -20 || true
            return 1
        fi
    done
}

# publish_to_onegate: PUT a key-value pair to the VM's USER_TEMPLATE via OneGate.
# Non-fatal on failure -- SuperNode operates without OneGate publication.
publish_to_onegate()
{
    local key="$1"
    local value="$2"

    local onegate_token=""
    [ -f /run/one-context/token.txt ] && onegate_token=$(cat /run/one-context/token.txt)

    if [ -z "${ONEGATE_ENDPOINT:-}" ] || [ -z "${onegate_token}" ]; then
        return 0
    fi

    if ! curl -s -X PUT "${ONEGATE_ENDPOINT}/vm" \
        -H "X-ONEGATE-TOKEN: ${onegate_token}" \
        -H "X-ONEGATE-VMID: ${VMID:-}" \
        -d "${key}=${value}" 2>/dev/null; then
        msg warning "Failed to publish ${key}=${value} to OneGate"
    fi
}

# start_dcgm_exporter: Start the DCGM GPU metrics exporter sidecar container.
# Pulls the image at boot (not pre-baked) to keep the base QCOW2 image lean.
# Non-fatal on failure -- degraded monitoring, training continues.
start_dcgm_exporter()
{
    local dcgm_image="nvcr.io/nvidia/k8s/dcgm-exporter:4.5.1-4.8.0-distroless"

    msg info "Pulling DCGM Exporter image (boot-time pull)"
    if ! docker pull "${dcgm_image}" 2>/dev/null; then
        msg warning "Failed to pull DCGM Exporter image; GPU metrics unavailable"
        return 0
    fi

    docker rm -f "${DCGM_CONTAINER}" 2>/dev/null || true
    if ! docker run -d \
        --name "${DCGM_CONTAINER}" \
        --restart unless-stopped \
        --gpus all \
        --cap-add SYS_ADMIN \
        -p 9400:9400 \
        "${dcgm_image}"; then
        msg warning "Failed to start DCGM Exporter; GPU metrics unavailable"
        return 0
    fi

    # Write a systemd unit so DCGM lifecycle is tied to the SuperNode
    cat > /etc/systemd/system/dcgm-exporter.service <<'EOF'
[Unit]
Description=DCGM GPU Metrics Exporter
After=docker.service flower-supernode.service
Requires=docker.service
PartOf=flower-supernode.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f dcgm-exporter
ExecStart=/usr/bin/docker start -a dcgm-exporter
ExecStop=/usr/bin/docker stop -t 10 dcgm-exporter

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable dcgm-exporter.service
    msg info "DCGM Exporter started on port 9400"
}
