#!/usr/bin/env bash

# Flower SuperNode appliance lifecycle script for the one-apps framework.
# Implements APPL-02: SuperNode marketplace appliance with Docker-in-VM
# architecture, OneGate dynamic discovery, and TLS trust.
#
# Spec references:
#   spec/02-supernode-appliance.md  -- boot sequence, discovery, health check
#   spec/03-contextualization-reference.md -- variable definitions
#   spec/05-supernode-tls-trust.md  -- CA cert retrieval

### Flower SuperNode Configuration ############################################

FLOWER_DIR="/opt/flower"
FLOWER_SCRIPTS_DIR="${FLOWER_DIR}/scripts"
FLOWER_CONFIG_DIR="${FLOWER_DIR}/config"
FLOWER_CERTS_DIR="${FLOWER_DIR}/certs"
FLOWER_DATA_DIR="${FLOWER_DIR}/data"
FLOWER_CONTAINER="flower-supernode"
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
    'ONEAPP_FL_FRAMEWORK'              'configure' 'ML framework (pytorch|tensorflow|sklearn)'                  'pytorch'
    'ONEAPP_FL_SUPERLINK_ADDRESS'      'configure' 'SuperLink Fleet API address (host:port)'                    ''
    'ONEAPP_FL_NODE_CONFIG'            'configure' 'Space-separated key=value node config'                      ''
    'ONEAPP_FL_MAX_RETRIES'            'configure' 'Max reconnection attempts (0=unlimited)'                    '0'
    'ONEAPP_FL_MAX_WAIT_TIME'          'configure' 'Max wait time for connection in seconds (0=unlimited)'      '0'
    'ONEAPP_FL_ISOLATION'              'configure' 'App execution isolation mode (subprocess|process)'          'subprocess'
    'ONEAPP_FL_LOG_LEVEL'              'configure' 'Log verbosity (DEBUG|INFO|WARNING|ERROR)'                   'INFO'
    # Phase 2: TLS (secure by default)
    'ONEAPP_FL_TLS_ENABLED'            'configure' 'Enable TLS encryption (YES|NO)'                             'YES'
)

### Default Value Assignments #################################################
# Applied at load AND re-applied after re-sourcing one_env in service_configure.
# A OneFlow service only supplies the inputs it exposes (framework, TLS); any
# other context var the VM template references arrives as an EMPTY string, which
# would otherwise clobber these defaults and fail validation (empty log level,
# empty image tag). Re-applying with :- restores the defaults for empty values.
apply_config_defaults() {
    ONEAPP_FLOWER_VERSION="${ONEAPP_FLOWER_VERSION:-1.25.0}"
    ONEAPP_FL_FRAMEWORK="${ONEAPP_FL_FRAMEWORK:-pytorch}"
    ONEAPP_FL_SUPERLINK_ADDRESS="${ONEAPP_FL_SUPERLINK_ADDRESS:-}"
    ONEAPP_FL_NODE_CONFIG="${ONEAPP_FL_NODE_CONFIG:-}"
    ONEAPP_FL_MAX_RETRIES="${ONEAPP_FL_MAX_RETRIES:-0}"
    ONEAPP_FL_MAX_WAIT_TIME="${ONEAPP_FL_MAX_WAIT_TIME:-0}"
    ONEAPP_FL_ISOLATION="${ONEAPP_FL_ISOLATION:-subprocess}"
    ONEAPP_FL_LOG_LEVEL="${ONEAPP_FL_LOG_LEVEL:-INFO}"
    ONEAPP_FL_TLS_ENABLED="${ONEAPP_FL_TLS_ENABLED:-YES}"
}
apply_config_defaults

###############################################################################
# Mandatory lifecycle functions -- called by the one-apps service manager
###############################################################################

# service_install: runs once during Packer image build.
# Installs Docker CE, pre-pulls the Flower SuperNode image, installs jq, and
# creates the /opt/flower directory tree.
service_install()
{
    mkdir -p "$ONE_SERVICE_SETUP_DIR"

    msg info "Installing Docker CE"
    install_docker

    msg info "Installing jq, curl, netcat and the firewall stack (ufw + iptables)"
    # iptables-persistent is intentionally omitted: harden_firewall re-applies
    # rules on every boot, so persistence-to-disk is not required and the
    # package's debconf dependencies can break non-interactive installs.
    if ! apt-get install -y jq curl netcat-openbsd ufw iptables; then
        msg error "Failed to install jq/curl/netcat/firewall packages"
        exit 1
    fi

    # Bake ONLY the default (pytorch) framework image to keep the qcow2 small
    # enough for the marketplace CLONING timeout. tensorflow/sklearn are built
    # lazily on first boot when ONEAPP_FL_FRAMEWORK selects them (see
    # ensure_framework_image). The stock flwr/supernode image is NOT pulled --
    # the appliance runs its own glibc-based framework images instead.
    msg info "Building default framework image (pytorch)"
    build_framework_image "pytorch"

    # Reclaim the BuildKit cache (downloaded wheels) so it does not inflate the
    # exported qcow2.
    docker builder prune -af >/dev/null 2>&1 || true

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

    # Step 2: source one-context environment, then re-apply defaults. Sourcing
    # one_env imports the raw context, where a OneFlow service leaves unsupplied
    # inputs as empty strings; apply_config_defaults restores their defaults.
    if [ -f /run/one-context/one_env ]; then
        # shellcheck disable=SC1091
        . /run/one-context/one_env
        apply_config_defaults
    fi

    # Step 3: validate configuration
    validate_config || exit 1

    # Step 4: create mount dirs with correct ownership
    mkdir -p "${FLOWER_DATA_DIR}" "${FLOWER_CERTS_DIR}" "${FLOWER_CONFIG_DIR}"
    chown -R 49999:49999 "${FLOWER_DATA_DIR}" "${FLOWER_CERTS_DIR}"

    # Harden the host firewall: default-deny inbound, block outbound SMTP. The
    # SuperNode publishes no inbound FL ports (it connects out to the SuperLink),
    # so this mainly prevents a compromised training workload from sending spam.
    harden_firewall

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

    # Determine container image version and framework-specific image
    VERSION="${ONEAPP_FLOWER_VERSION}"

    case "${ONEAPP_FL_FRAMEWORK}" in
        pytorch)    IMAGE_TAG="flower-supernode-pytorch:${VERSION}" ;;
        tensorflow) IMAGE_TAG="flower-supernode-tensorflow:${VERSION}" ;;
        sklearn)    IMAGE_TAG="flower-supernode-sklearn:${VERSION}" ;;
        *)          IMAGE_TAG="flower-supernode-pytorch:${VERSION}" ;;
    esac
    msg info "Using ML framework image: ${IMAGE_TAG}"

    # Lazy build: only pytorch is baked into the image; build the selected
    # framework image now if it is missing.
    ensure_framework_image "${ONEAPP_FL_FRAMEWORK}" || \
        msg warning "Could not build ${ONEAPP_FL_FRAMEWORK} image -- container start may fail"

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

    # Persist variables needed by service_bootstrap (separate process invocation)
    cat > "${FLOWER_CONFIG_DIR}/configure.state" <<EOF
SUPERLINK_ADDRESS='${SUPERLINK_ADDRESS}'
VERSION='${VERSION}'
IMAGE_TAG='${IMAGE_TAG}'
TLS_FLAGS='${TLS_FLAGS}'
TLS_VOLUME_FLAGS='${TLS_VOLUME_FLAGS}'
TLS_MODE='${TLS_MODE}'
EOF
    chmod 600 "${FLOWER_CONFIG_DIR}/configure.state"

    # Write service report (only when the framework provides the path; never
    # fall back to /etc/one-appliance/config, which the one-apps tool owns).
    if [ -n "${ONE_SERVICE_REPORT:-}" ]; then
        cat > "${ONE_SERVICE_REPORT}" <<EOF
[Flower SuperNode]
superlink  = ${SUPERLINK_ADDRESS}
version    = ${VERSION}
framework  = ${ONEAPP_FL_FRAMEWORK}
image      = ${IMAGE_TAG}
isolation  = ${ONEAPP_FL_ISOLATION}
tls        = ${TLS_MODE}
firewall   = default-deny inbound, outbound SMTP blocked
EOF
        chmod 600 "${ONE_SERVICE_REPORT}" 2>/dev/null
    fi

    msg info "CONFIGURATION FINISHED"
    return 0
}

# service_bootstrap: runs after configure, starts the container.
# Waits for Docker, handles version overrides, starts the systemd service,
# waits for health, and publishes to OneGate.
service_bootstrap()
{
    msg info "--- SuperNode bootstrap stage ---"

    # Restore variables persisted by service_configure()
    if [ -f "${FLOWER_CONFIG_DIR}/configure.state" ]; then
        # shellcheck disable=SC1091
        . "${FLOWER_CONFIG_DIR}/configure.state"
    else
        msg error "Missing ${FLOWER_CONFIG_DIR}/configure.state -- service_configure did not run"
        exit 1
    fi

    # Step 8: wait for Docker daemon
    wait_for_docker || { msg error "Docker daemon not available"; exit 1; }

    # Step 10: handle version override
    if [ "${VERSION}" != "${PREBAKED_VERSION}" ]; then
        msg info "Requested version ${VERSION} differs from prebaked ${PREBAKED_VERSION}"
        msg warning "Framework images are prebaked; falling back to prebaked ${PREBAKED_VERSION}"
        VERSION="${PREBAKED_VERSION}"
        # Re-derive IMAGE_TAG with corrected version
        case "${ONEAPP_FL_FRAMEWORK:-pytorch}" in
            pytorch)    IMAGE_TAG="flower-supernode-pytorch:${VERSION}" ;;
            tensorflow) IMAGE_TAG="flower-supernode-tensorflow:${VERSION}" ;;
            sklearn)    IMAGE_TAG="flower-supernode-sklearn:${VERSION}" ;;
            *)          IMAGE_TAG="flower-supernode-pytorch:${VERSION}" ;;
        esac
    fi

    # Create the container (Step 11 prep -- container creation separate from systemd start)
    docker rm -f "${FLOWER_CONTAINER}" 2>/dev/null || true

    # Build the docker command as an ARRAY (never eval a string): operator-
    # supplied values such as ONEAPP_FL_NODE_CONFIG stay individual quoted
    # elements, so they cannot inject shell commands during contextualization.
    # The whitespace-bearing flag groups we generate ourselves (TLS flags)
    # are intentionally left unquoted so they split into separate arguments.
    local -a create_cmd=(docker create --name "${FLOWER_CONTAINER}" --restart unless-stopped)
    create_cmd+=(-v "${FLOWER_DATA_DIR}:/app/data:ro")
    # shellcheck disable=SC2206
    [ -n "${TLS_VOLUME_FLAGS}" ]   && create_cmd+=(${TLS_VOLUME_FLAGS})
    create_cmd+=(--env-file "${FLOWER_CONFIG_DIR}/supernode.env")
    create_cmd+=("${IMAGE_TAG}")
    # shellcheck disable=SC2206
    create_cmd+=(${TLS_FLAGS})
    create_cmd+=(--superlink "${SUPERLINK_ADDRESS}")
    create_cmd+=(--isolation "${ONEAPP_FL_ISOLATION}")
    create_cmd+=(--node-config "${ONEAPP_FL_NODE_CONFIG}")
    create_cmd+=(--max-retries "${ONEAPP_FL_MAX_RETRIES}")
    create_cmd+=(--max-wait-time "${ONEAPP_FL_MAX_WAIT_TIME}")

    msg info "Creating container: ${create_cmd[*]}"
    "${create_cmd[@]}" || { msg error "Failed to create container"; exit 1; }

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
    publish_to_onegate "FL_FRAMEWORK" "${ONEAPP_FL_FRAMEWORK:-pytorch}"

    msg info "BOOTSTRAP FINISHED"
    return 0
}

service_help()
{
    msg info "Flower SuperNode appliance -- Federated Learning client node"
    msg info ""
    msg info "Context variables:"
    msg info "  ONEAPP_FLOWER_VERSION            Flower version (default: 1.25.0)"
    msg info "  ONEAPP_FL_FRAMEWORK              ML framework: pytorch, tensorflow, sklearn (default: pytorch)"
    msg info "  ONEAPP_FL_SUPERLINK_ADDRESS      Static SuperLink address (host:port)"
    msg info "  ONEAPP_FL_NODE_CONFIG            key=value pairs for ClientApp"
    msg info "  ONEAPP_FL_TLS_ENABLED            Enable TLS encryption (default: YES)"
    msg info ""
    msg info "Logs: /var/log/one-appliance/"
    msg info "Container logs: docker logs flower-supernode"
    return 0
}

service_cleanup()
{
    # No-op: the one-appliance framework calls cleanup between lifecycle stages,
    # but we must not destroy the container that bootstrap just created.
    # Container lifecycle is managed by systemd (Restart=on-failure).
    :
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
        | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
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

# build_framework_image: build ONE framework image on demand.
# The official flwr/supernode image is Alpine (musl) which lacks the glibc that
# PyTorch/TensorFlow manylinux wheels need, so we build from python:3.12-slim.
# NumPy 2.x requires SSE4.1 (x86_v2) which some KVM VMs lack, so pin 1.26.4.
# Only the default (pytorch) image is baked at build time; the others are built
# lazily on first boot to keep the exported qcow2 within the marketplace
# CLONING timeout.
build_framework_image()
{
    local _framework="$1"
    local VER="${PREBAKED_VERSION}"
    local _tag="flower-supernode-${_framework}:${VER}"

    case "${_framework}" in
        pytorch)
            msg info "Building ${_tag}"
            docker build -t "${_tag}" - <<'DOCKERFILE'
FROM python:3.12-slim
RUN pip install --no-cache-dir \
    'numpy==1.26.4' \
    'flwr[simulation]==1.25.0' \
    'torch==2.5.1+cpu' 'torchvision==0.20.1+cpu' \
    --extra-index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir 'flwr-datasets[vision]>=0.4.0'
ENTRYPOINT ["flower-supernode"]
DOCKERFILE
            ;;
        tensorflow)
            msg info "Building ${_tag}"
            docker build -t "${_tag}" - <<'DOCKERFILE'
FROM python:3.12-slim
RUN pip install --no-cache-dir \
    'numpy==1.26.4' \
    'flwr[simulation]==1.25.0' \
    'tensorflow-cpu==2.18.1' \
    'flwr-datasets[vision]>=0.4.0'
ENTRYPOINT ["flower-supernode"]
DOCKERFILE
            ;;
        sklearn)
            msg info "Building ${_tag}"
            docker build -t "${_tag}" - <<'DOCKERFILE'
FROM python:3.12-slim
RUN pip install --no-cache-dir \
    'numpy==1.26.4' \
    'flwr[simulation]==1.25.0' \
    'scikit-learn==1.5.2' \
    'flwr-datasets[vision]>=0.4.0'
ENTRYPOINT ["flower-supernode"]
DOCKERFILE
            ;;
        *)
            msg error "Unknown framework '${_framework}' -- cannot build image"
            return 1
            ;;
    esac
}

# ensure_framework_image: build the selected framework image at boot if it is
# not already present (lazy fetch for non-default frameworks).
ensure_framework_image()
{
    local _framework="$1"
    local _tag="flower-supernode-${_framework}:${PREBAKED_VERSION}"

    if docker image inspect "${_tag}" >/dev/null 2>&1; then
        return 0
    fi

    msg info "Framework image ${_tag} not baked -- building it now (first boot)"
    if ! build_framework_image "${_framework}"; then
        msg error "Failed to build framework image ${_tag}"
        return 1
    fi
    docker builder prune -af >/dev/null 2>&1 || true
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

    # FL_FRAMEWORK: enum
    case "${ONEAPP_FL_FRAMEWORK}" in
        pytorch|tensorflow|sklearn) ;;
        *) msg error "Invalid ONEAPP_FL_FRAMEWORK: '${ONEAPP_FL_FRAMEWORK}'. Must be pytorch, tensorflow, or sklearn"
           errors=$((errors + 1)) ;;
    esac

    # FL_SUPERLINK_ADDRESS: host:port if set
    if [ -n "${ONEAPP_FL_SUPERLINK_ADDRESS}" ] && \
       ! [[ "${ONEAPP_FL_SUPERLINK_ADDRESS}" =~ ^[^:]+:[0-9]+$ ]]; then
        msg error "Invalid ONEAPP_FL_SUPERLINK_ADDRESS: '${ONEAPP_FL_SUPERLINK_ADDRESS}'. Expected host:port"
        errors=$((errors + 1))
    fi

    # FL_NODE_CONFIG: defense-in-depth denylist. The container is started via an
    # argv array (no eval), so injection is already impossible; this only blocks
    # shell metacharacters as belt-and-suspenders while still allowing the full
    # set of valid Flower run-config values (paths, quotes, colons, etc.).
    if [ -n "${ONEAPP_FL_NODE_CONFIG}" ] && \
       [[ "${ONEAPP_FL_NODE_CONFIG}" == *[\$\`\;\|\&\<\>\(\)\\]* || "${ONEAPP_FL_NODE_CONFIG}" == *$'\n'* ]]; then
        msg error "Invalid ONEAPP_FL_NODE_CONFIG: '${ONEAPP_FL_NODE_CONFIG}'. Must not contain shell metacharacters (\$ \` ; | & < > ( ) \\ or newlines)"
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

    if [ "${errors}" -gt 0 ]; then
        msg error "${errors} configuration error(s). Aborting boot."
        return 1
    fi

    msg info "Configuration validation passed"
    return 0
}

# discover_superlink: Resolve the SuperLink Fleet API address via OneGate.
# Implements the retry loop from spec/02 Section 6d.
# Outputs the discovered address on stdout; returns non-zero on failure.
discover_superlink()
{
    # NOTE: This function returns the address on stdout, so all msg info
    # calls must redirect to stderr to avoid polluting the return value.

    # Read OneGate environment
    local onegate_endpoint="${ONEGATE_ENDPOINT:-}"
    local onegate_token=""
    local vmid="${VMID:-}"

    onegate_token="${TOKENTXT:-}"

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
    msg info "OneGate connectivity verified" >&2

    # Step 1: Get SuperLink VM ID from service endpoint
    local service_json superlink_vmid
    service_json=$(curl -s "${onegate_endpoint}/service" \
        -H "X-ONEGATE-TOKEN: ${onegate_token}" \
        -H "X-ONEGATE-VMID: ${vmid}" 2>/dev/null)

    superlink_vmid=$(echo "${service_json}" | jq -r '
        .SERVICE.roles[]
        | select(.name == "superlink")
        | .nodes[0].vm_info.VM.ID // empty
    ' 2>/dev/null)

    if [ -z "${superlink_vmid}" ]; then
        msg error "Could not find SuperLink VM ID from service endpoint"
        return 1
    fi
    msg info "Found SuperLink VM ID: ${superlink_vmid}" >&2

    # Step 2: Retry loop — query SuperLink VM directly for FL_ENDPOINT.
    # Bounded: up to 30 attempts with a fixed 10s wait between them.
    local max_retries=30
    local interval=10
    local attempt=1
    local fl_endpoint=""

    while [ "${attempt}" -le "${max_retries}" ]; do
        # Use onegate CLI for cross-VM query (curl /vm/<id> not supported)
        local vm_json
        vm_json=$(onegate vm show "${superlink_vmid}" --json 2>/dev/null)

        # Try FL_ENDPOINT from USER_TEMPLATE first
        fl_endpoint=$(echo "${vm_json}" | jq -r '
            .VM.USER_TEMPLATE.FL_ENDPOINT // empty
        ' 2>/dev/null)

        # Fallback: derive from NIC IP (assume port 9092)
        if [ -z "${fl_endpoint}" ] && [ -n "${vm_json}" ]; then
            local sl_ip
            sl_ip=$(echo "${vm_json}" | jq -r '
                .VM.TEMPLATE.NIC[0].IP // empty
            ' 2>/dev/null)
            if [ -n "${sl_ip}" ]; then
                fl_endpoint="${sl_ip}:9092"
                msg info "Derived SuperLink endpoint from NIC IP: ${fl_endpoint}" >&2
            fi
        fi

        if [ -n "${fl_endpoint}" ]; then
            msg info "Discovered SuperLink at ${fl_endpoint} (attempt ${attempt})" >&2
            echo "${fl_endpoint}"
            return 0
        fi

        msg info "SuperLink not ready, waiting ${interval}s... (attempt ${attempt})" >&2
        sleep "${interval}"
        attempt=$((attempt + 1))
    done

    msg error "SuperLink discovery timed out after ${max_retries} attempts"
    return 1
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
            local onegate_token="${TOKENTXT:-}"

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
# Retrieves the FL_CA_CERT published by the SuperLink via OneGate.
retrieve_ca_cert()
{
    local cert_path="${FLOWER_CERTS_DIR}/ca.crt"

    # Retrieve from OneGate (FL_CA_CERT published on the SuperLink VM).
    # The plain GET /service response does not reliably include the SuperLink's
    # full USER_TEMPLATE, so resolve the SuperLink VM id from /service and then
    # query that VM directly with `onegate vm show <id> --json` (the same robust
    # path discover_superlink uses). Retry briefly to absorb publish timing.
    if [ -n "${ONEGATE_ENDPOINT:-}" ]; then
        local onegate_token="${TOKENTXT:-}"

        if [ -n "${onegate_token}" ]; then
            local service_json superlink_vmid
            service_json=$(curl -s "${ONEGATE_ENDPOINT}/service" \
                -H "X-ONEGATE-TOKEN: ${onegate_token}" \
                -H "X-ONEGATE-VMID: ${VMID:-}" 2>/dev/null)
            superlink_vmid=$(echo "${service_json}" | jq -r '
                .SERVICE.roles[]
                | select(.name == "superlink")
                | .nodes[0].vm_info.VM.ID // empty
            ' 2>/dev/null)

            if [ -n "${superlink_vmid}" ]; then
                local _attempt ca_b64 vm_json
                for _attempt in $(seq 1 12); do
                    vm_json=$(onegate vm show "${superlink_vmid}" --json 2>/dev/null)
                    ca_b64=$(echo "${vm_json}" | jq -r '.VM.USER_TEMPLATE.FL_CA_CERT // empty' 2>/dev/null)
                    if [ -n "${ca_b64}" ]; then
                        msg info "CA certificate retrieved from OneGate (SuperLink VM ${superlink_vmid})"
                        echo "${ca_b64}" | base64 -d > "${cert_path}" 2>/dev/null
                        finalize_ca_cert "${cert_path}"
                        return $?
                    fi
                    msg info "Waiting for SuperLink to publish FL_CA_CERT (attempt ${_attempt})"
                    sleep 5
                done
            fi
        fi
    fi

    msg error "TLS enabled but no CA certificate available (ensure the SuperLink publishes FL_CA_CERT)"
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

    local onegate_token="${TOKENTXT:-}"
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

    local onegate_token="${TOKENTXT:-}"

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

# get_primary_ip: first non-loopback IPv4 address (primary route interface).
get_primary_ip()
{
    local _ip
    _ip=$(ip -o -f inet route show to default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "${_ip}" ]; then
        ip -o -f inet addr show dev "${_ip}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
        return 0
    fi
    hostname -I 2>/dev/null | awk '{print $1}'
}

# get_primary_cidr: connected subnet of the default-route interface. Anchoring
# to that interface is required because once Docker is up, docker0's
# 172.17.0.0/16 link route can sort ahead of the real FL subnet and would
# otherwise scope the firewall to the wrong network.
get_primary_cidr()
{
    local _if _cidr
    _if=$(ip -o -f inet route show to default 2>/dev/null | awk '{print $5; exit}')
    [ -n "${_if}" ] && _cidr=$(ip -o -f inet route show scope link dev "${_if}" 2>/dev/null | awk '{print $1; exit}')
    echo "${_cidr}"
}

# harden_firewall: default-deny inbound (allow SSH), block outbound SMTP, and
# scope any Flower ports to the FL private subnet. Idempotent and
# best-effort so it never aborts the boot. The SuperNode publishes no inbound
# FL ports, so this primarily stops a compromised training workload from being
# used to relay spam (the cause of the prior Scaleway abuse report).
harden_firewall()
{
    msg info "Hardening host firewall (default-deny inbound, SMTP egress block)"

    FL_PRIVATE_CIDR=$(get_primary_cidr)
    [ -z "${FL_PRIVATE_CIDR}" ] && FL_PRIVATE_CIDR="$(get_primary_ip)/24"
    local _ext_if
    _ext_if=$(ip -o -f inet route show to default 2>/dev/null | awk '{print $5; exit}')

    if command -v ufw >/dev/null 2>&1; then
        ufw --force reset      >/dev/null 2>&1 || true
        ufw default deny incoming  >/dev/null 2>&1 || true
        ufw default allow outgoing >/dev/null 2>&1 || true
        ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1 || true
        ufw logging low        >/dev/null 2>&1 || true
        ufw --force enable     >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables -L DOCKER-USER >/dev/null 2>&1 || iptables -N DOCKER-USER 2>/dev/null || true

        iptables -C OUTPUT -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null \
            || iptables -A OUTPUT -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null || true
        iptables -C DOCKER-USER -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null \
            || iptables -I DOCKER-USER -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null || true

        if [ -n "${_ext_if}" ]; then
            iptables -C DOCKER-USER -i "${_ext_if}" ! -s "${FL_PRIVATE_CIDR}" -p tcp -m multiport --dports 9091,9092,9093,9101,9400 -j DROP 2>/dev/null \
                || iptables -I DOCKER-USER -i "${_ext_if}" ! -s "${FL_PRIVATE_CIDR}" -p tcp -m multiport --dports 9091,9092,9093,9101,9400 -j DROP 2>/dev/null || true
        fi
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C OUTPUT -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null \
            || ip6tables -A OUTPUT -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null || true
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    msg info "Firewall hardened (FL ports limited to ${FL_PRIVATE_CIDR}, SMTP egress blocked)"
}
