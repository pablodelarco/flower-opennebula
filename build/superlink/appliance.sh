#!/usr/bin/env bash
# --------------------------------------------------------------------------
# Flower SuperLink -- ONE-APPS Appliance Lifecycle Script
#
# Implements the one-apps service_* interface for a Flower federated
# learning SuperLink packaged as an OpenNebula marketplace appliance.
# See spec/01-superlink-appliance.md for the full specification.
# --------------------------------------------------------------------------

ONE_SERVICE_NAME='Service Flower SuperLink - Federated Learning Coordinator'
ONE_SERVICE_VERSION='1.25.0'
ONE_SERVICE_BUILD=$(date +%s)
ONE_SERVICE_SHORT_DESCRIPTION='Flower SuperLink FL coordinator (Docker-in-VM)'
ONE_SERVICE_DESCRIPTION='Flower federated learning SuperLink appliance. Runs the
flower-superlink gRPC coordinator inside a Docker container managed by systemd.
Supports zero-config deployment, optional TLS, strategy selection, model
checkpointing, and Prometheus metrics export.'
ONE_SERVICE_RECONFIGURABLE=true

# --------------------------------------------------------------------------
# ONE_SERVICE_PARAMS -- flat array, 4-element stride:
#   'VARNAME' 'lifecycle_step' 'Description' 'default_value'
#
# All variables are bound to the 'configure' step so they are re-read on
# every VM boot / reconfigure cycle.
# --------------------------------------------------------------------------
ONE_SERVICE_PARAMS=(
    # --- Core configuration (Phase 1) ---
    'ONEAPP_FLOWER_VERSION'           'configure' 'Flower Docker image version tag'                        '1.25.0'
    'ONEAPP_FL_NUM_ROUNDS'            'configure' 'Number of federated learning rounds'                    '3'
    'ONEAPP_FL_STRATEGY'              'configure' 'Aggregation strategy (FedAvg|FedProx|FedAdam|Krum|Bulyan|FedTrimmedAvg)' 'FedAvg'
    'ONEAPP_FL_MIN_FIT_CLIENTS'       'configure' 'Minimum clients for training round'                     '2'
    'ONEAPP_FL_MIN_EVALUATE_CLIENTS'  'configure' 'Minimum clients for evaluation'                         '2'
    'ONEAPP_FL_MIN_AVAILABLE_CLIENTS' 'configure' 'Minimum available clients to start'                     '2'
    'ONEAPP_FL_FLEET_API_ADDRESS'     'configure' 'Fleet API listen address (host:port)'                   '0.0.0.0:9092'
    'ONEAPP_FL_CONTROL_API_ADDRESS'   'configure' 'Control API listen address (host:port)'                 '0.0.0.0:9093'
    'ONEAPP_FL_ISOLATION'             'configure' 'App execution isolation mode (subprocess|process)'      'subprocess'
    'ONEAPP_FL_DATABASE'              'configure' 'Database path for state persistence'                    'state/state.db'
    'ONEAPP_FL_LOG_LEVEL'             'configure' 'Log verbosity (DEBUG|INFO|WARNING|ERROR)'               'INFO'

    # --- Strategy parameters (Phase 5) ---
    'ONEAPP_FL_PROXIMAL_MU'           'configure' 'FedProx proximal term (mu)'                             '1.0'
    'ONEAPP_FL_SERVER_LR'             'configure' 'Server-side learning rate (FedAdam)'                    '0.1'
    'ONEAPP_FL_CLIENT_LR'             'configure' 'Client-side learning rate (FedAdam)'                    '0.1'
    'ONEAPP_FL_NUM_MALICIOUS'         'configure' 'Expected malicious clients (Krum/Bulyan)'               '0'
    'ONEAPP_FL_TRIM_BETA'             'configure' 'Trim fraction per tail (FedTrimmedAvg)'                 '0.2'

    # --- Checkpointing (Phase 5) ---
    'ONEAPP_FL_CHECKPOINT_ENABLED'    'configure' 'Enable model checkpointing (YES|NO)'                    'NO'
    'ONEAPP_FL_CHECKPOINT_INTERVAL'   'configure' 'Save checkpoint every N rounds'                         '5'
    'ONEAPP_FL_CHECKPOINT_PATH'       'configure' 'Checkpoint directory (container path)'                  '/app/checkpoints'

    # --- gRPC keepalive (Phase 7) ---
    'ONEAPP_FL_GRPC_KEEPALIVE_TIME'    'configure' 'gRPC keepalive interval in seconds'                    '60'
    'ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT' 'configure' 'gRPC keepalive ACK timeout in seconds'                 '20'

    # --- TLS configuration (Phase 2) ---
    'ONEAPP_FL_TLS_ENABLED'           'configure' 'Enable TLS encryption (YES|NO)'                         'NO'
    'ONEAPP_FL_SSL_CA_CERTFILE'       'configure' 'Operator CA certificate (base64-encoded PEM)'           ''
    'ONEAPP_FL_SSL_CERTFILE'          'configure' 'Operator server certificate (base64-encoded PEM)'       ''
    'ONEAPP_FL_SSL_KEYFILE'           'configure' 'Operator server private key (base64-encoded PEM)'       ''
    'ONEAPP_FL_CERT_EXTRA_SAN'        'configure' 'Additional SAN entries for auto-generated cert'         ''

    # --- Monitoring (Phase 8) ---
    'ONEAPP_FL_METRICS_ENABLED'       'configure' 'Enable Prometheus metrics exporter (YES|NO)'            'NO'
    'ONEAPP_FL_METRICS_PORT'          'configure' 'Prometheus metrics exporter port'                        '9101'
    'ONEAPP_FL_LOG_FORMAT'            'configure' 'Log output format (text|json)'                           'text'
)

# --------------------------------------------------------------------------
# Default value assignments
# --------------------------------------------------------------------------
ONEAPP_FLOWER_VERSION="${ONEAPP_FLOWER_VERSION:-1.25.0}"
ONEAPP_FL_NUM_ROUNDS="${ONEAPP_FL_NUM_ROUNDS:-3}"
ONEAPP_FL_STRATEGY="${ONEAPP_FL_STRATEGY:-FedAvg}"
ONEAPP_FL_MIN_FIT_CLIENTS="${ONEAPP_FL_MIN_FIT_CLIENTS:-2}"
ONEAPP_FL_MIN_EVALUATE_CLIENTS="${ONEAPP_FL_MIN_EVALUATE_CLIENTS:-2}"
ONEAPP_FL_MIN_AVAILABLE_CLIENTS="${ONEAPP_FL_MIN_AVAILABLE_CLIENTS:-2}"
ONEAPP_FL_FLEET_API_ADDRESS="${ONEAPP_FL_FLEET_API_ADDRESS:-0.0.0.0:9092}"
ONEAPP_FL_CONTROL_API_ADDRESS="${ONEAPP_FL_CONTROL_API_ADDRESS:-0.0.0.0:9093}"
ONEAPP_FL_ISOLATION="${ONEAPP_FL_ISOLATION:-subprocess}"
ONEAPP_FL_DATABASE="${ONEAPP_FL_DATABASE:-state/state.db}"
ONEAPP_FL_LOG_LEVEL="${ONEAPP_FL_LOG_LEVEL:-INFO}"
ONEAPP_FL_PROXIMAL_MU="${ONEAPP_FL_PROXIMAL_MU:-1.0}"
ONEAPP_FL_SERVER_LR="${ONEAPP_FL_SERVER_LR:-0.1}"
ONEAPP_FL_CLIENT_LR="${ONEAPP_FL_CLIENT_LR:-0.1}"
ONEAPP_FL_NUM_MALICIOUS="${ONEAPP_FL_NUM_MALICIOUS:-0}"
ONEAPP_FL_TRIM_BETA="${ONEAPP_FL_TRIM_BETA:-0.2}"
ONEAPP_FL_CHECKPOINT_ENABLED="${ONEAPP_FL_CHECKPOINT_ENABLED:-NO}"
ONEAPP_FL_CHECKPOINT_INTERVAL="${ONEAPP_FL_CHECKPOINT_INTERVAL:-5}"
ONEAPP_FL_CHECKPOINT_PATH="${ONEAPP_FL_CHECKPOINT_PATH:-/app/checkpoints}"
ONEAPP_FL_GRPC_KEEPALIVE_TIME="${ONEAPP_FL_GRPC_KEEPALIVE_TIME:-60}"
ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT="${ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT:-20}"
ONEAPP_FL_TLS_ENABLED="${ONEAPP_FL_TLS_ENABLED:-NO}"
ONEAPP_FL_SSL_CA_CERTFILE="${ONEAPP_FL_SSL_CA_CERTFILE:-}"
ONEAPP_FL_SSL_CERTFILE="${ONEAPP_FL_SSL_CERTFILE:-}"
ONEAPP_FL_SSL_KEYFILE="${ONEAPP_FL_SSL_KEYFILE:-}"
ONEAPP_FL_CERT_EXTRA_SAN="${ONEAPP_FL_CERT_EXTRA_SAN:-}"
ONEAPP_FL_METRICS_ENABLED="${ONEAPP_FL_METRICS_ENABLED:-NO}"
ONEAPP_FL_METRICS_PORT="${ONEAPP_FL_METRICS_PORT:-9101}"
ONEAPP_FL_LOG_FORMAT="${ONEAPP_FL_LOG_FORMAT:-text}"

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
readonly FLOWER_BASE_DIR="/opt/flower"
readonly FLOWER_CERT_DIR="${FLOWER_BASE_DIR}/certs"
readonly FLOWER_CONFIG_DIR="${FLOWER_BASE_DIR}/config"
readonly FLOWER_STATE_DIR="${FLOWER_BASE_DIR}/state"
readonly FLOWER_SCRIPTS_DIR="${FLOWER_BASE_DIR}/scripts"
readonly FLOWER_SYSTEMD_UNIT="/etc/systemd/system/flower-superlink.service"
readonly FLOWER_ENV_FILE="${FLOWER_CONFIG_DIR}/superlink.env"
readonly FLOWER_UID=49999
readonly FLOWER_GID=49999

# ==========================================================================
#  LIFECYCLE: service_install  (Packer build-time, runs once)
# ==========================================================================
service_install() {
    msg info "Installing Flower SuperLink appliance components"

    # 1. Install Docker CE
    install_docker

    # 2. Pull the default Flower SuperLink image
    msg info "Pulling flwr/superlink:${ONEAPP_FLOWER_VERSION}"
    docker pull "flwr/superlink:${ONEAPP_FLOWER_VERSION}"

    # 3. Install OpenSSL (for TLS generation) and jq (for JSON parsing)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq openssl jq netcat-openbsd >/dev/null

    # 4. Create directory structure
    mkdir -p "${FLOWER_SCRIPTS_DIR}" \
             "${FLOWER_CONFIG_DIR}" \
             "${FLOWER_STATE_DIR}" \
             "${FLOWER_CERT_DIR}"

    # 5. Set ownership: state and certs dirs to Flower app user (UID 49999)
    chown "${FLOWER_UID}:${FLOWER_GID}" "${FLOWER_STATE_DIR}"
    chown "${FLOWER_UID}:${FLOWER_GID}" "${FLOWER_CERT_DIR}"
    chmod 0700 "${FLOWER_CERT_DIR}"

    # 6. Record pre-baked version for boot-time override detection
    echo "${ONEAPP_FLOWER_VERSION}" > "${FLOWER_BASE_DIR}/PREBAKED_VERSION"

    # 7. Stop Docker (layers persist in /var/lib/docker/)
    systemctl stop docker

    msg info "Flower SuperLink appliance install complete"
}

# ==========================================================================
#  LIFECYCLE: service_configure  (runs at each VM boot)
# ==========================================================================
service_configure() {
    msg info "Configuring Flower SuperLink"

    # 1. Validate all configuration values
    validate_config

    # 2. Ensure mount directories exist with correct ownership
    mkdir -p "${FLOWER_STATE_DIR}" "${FLOWER_CERT_DIR}" "${FLOWER_CONFIG_DIR}"
    chown "${FLOWER_UID}:${FLOWER_GID}" "${FLOWER_STATE_DIR}"
    chown "${FLOWER_UID}:${FLOWER_GID}" "${FLOWER_CERT_DIR}"
    chmod 0700 "${FLOWER_CERT_DIR}"
    chown root:root "${FLOWER_CONFIG_DIR}"
    chmod 0750 "${FLOWER_CONFIG_DIR}"

    # 3. Handle TLS certificates
    if [ "${ONEAPP_FL_TLS_ENABLED}" = "YES" ]; then
        if [ -n "${ONEAPP_FL_SSL_CA_CERTFILE}" ]; then
            msg info "TLS enabled -- decoding operator-provided certificates"
            decode_operator_certs
        else
            msg info "TLS enabled -- auto-generating CA and server certificates"
            generate_tls_certs
        fi
    else
        msg info "TLS disabled -- using insecure mode"
    fi

    # 4. Generate Docker environment file
    generate_superlink_env

    # 5. Generate systemd unit file
    generate_systemd_unit

    # 6. Generate Prometheus config if metrics enabled
    if [ "${ONEAPP_FL_METRICS_ENABLED}" = "YES" ]; then
        msg info "Metrics enabled -- port ${ONEAPP_FL_METRICS_PORT} will be exposed"
    fi

    # 7. Write service report
    local _report=""
    _report+="Flower SuperLink ${ONEAPP_FLOWER_VERSION}\n"
    _report+="Strategy: ${ONEAPP_FL_STRATEGY}\n"
    _report+="Rounds: ${ONEAPP_FL_NUM_ROUNDS}\n"
    _report+="Fleet API: ${ONEAPP_FL_FLEET_API_ADDRESS}\n"
    _report+="TLS: ${ONEAPP_FL_TLS_ENABLED}\n"
    _report+="Metrics: ${ONEAPP_FL_METRICS_ENABLED}\n"
    if [ -n "${ONE_SERVICE_REPORT:-}" ]; then
        echo -e "${_report}" > "${ONE_SERVICE_REPORT}"
    fi

    msg info "Flower SuperLink configuration complete"
}

# ==========================================================================
#  LIFECYCLE: service_bootstrap  (runs after configure, starts services)
# ==========================================================================
service_bootstrap() {
    msg info "Bootstrapping Flower SuperLink"

    # 1. Wait for Docker daemon readiness
    wait_for_docker

    # 2. Handle version override (pull if user requested different version)
    local _prebaked
    _prebaked=$(cat "${FLOWER_BASE_DIR}/PREBAKED_VERSION" 2>/dev/null || echo "unknown")

    if [ "${ONEAPP_FLOWER_VERSION}" != "${_prebaked}" ]; then
        msg info "Requested version ${ONEAPP_FLOWER_VERSION} differs from pre-baked ${_prebaked}"
        if docker pull "flwr/superlink:${ONEAPP_FLOWER_VERSION}" 2>/dev/null; then
            msg info "Successfully pulled flwr/superlink:${ONEAPP_FLOWER_VERSION}"
        else
            msg warning "Failed to pull version ${ONEAPP_FLOWER_VERSION} -- falling back to ${_prebaked}"
            ONEAPP_FLOWER_VERSION="${_prebaked}"
            # Regenerate config files with fallback version
            generate_superlink_env
            generate_systemd_unit
        fi
    fi

    # 3. Start the SuperLink service via systemd
    systemctl daemon-reload
    systemctl enable flower-superlink.service
    systemctl start flower-superlink.service

    # 4. Health check -- wait for Fleet API to accept connections
    wait_for_superlink

    # 5. Publish readiness to OneGate
    publish_to_onegate

    msg info "Flower SuperLink bootstrap complete -- FL_READY=YES"
}

# ==========================================================================
#  LIFECYCLE: service_help
# ==========================================================================
service_help() {
    cat <<'HELP'
Flower SuperLink Appliance
==========================

This appliance runs the Flower federated learning SuperLink coordinator
inside a Docker container managed by systemd.

Key configuration variables (set via OpenNebula context):
  ONEAPP_FLOWER_VERSION           Flower image tag (default: 1.25.0)
  ONEAPP_FL_STRATEGY              Aggregation strategy (default: FedAvg)
  ONEAPP_FL_NUM_ROUNDS            Training rounds (default: 3)
  ONEAPP_FL_TLS_ENABLED           Enable TLS (default: NO)
  ONEAPP_FL_METRICS_ENABLED       Enable Prometheus metrics (default: NO)

Ports:
  9091  ServerAppIo (internal)
  9092  Fleet API (SuperNode connections)
  9093  Control API (CLI management)
  9101  Prometheus metrics (optional)

Service management:
  systemctl status  flower-superlink
  systemctl restart flower-superlink
  journalctl -u flower-superlink -f

Configuration files:
  /opt/flower/config/superlink.env     Docker environment variables
  /etc/systemd/system/flower-superlink.service  Systemd unit

State and certificates:
  /opt/flower/state/    Persistent FL state (SQLite)
  /opt/flower/certs/    TLS certificates (when enabled)
HELP
}

# ==========================================================================
#  LIFECYCLE: service_cleanup
# ==========================================================================
service_cleanup() {
    msg info "Cleaning up Flower SuperLink"
    systemctl stop flower-superlink.service 2>/dev/null || true
    docker rm -f flower-superlink 2>/dev/null || true
}

# ==========================================================================
#  HELPER: install_docker
# ==========================================================================
install_docker() {
    msg info "Installing Docker CE from official repository"
    export DEBIAN_FRONTEND=noninteractive

    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker APT repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
        > /etc/apt/sources.list.d/docker.list

    # Install Docker CE + compose plugin
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    msg info "Docker CE installed successfully"
}

# ==========================================================================
#  HELPER: validate_config  (fail-fast on invalid values)
# ==========================================================================
validate_config() {
    local _errors=0

    # Positive integer checks
    local _var _val
    for _var in ONEAPP_FL_NUM_ROUNDS ONEAPP_FL_MIN_FIT_CLIENTS \
                ONEAPP_FL_MIN_EVALUATE_CLIENTS ONEAPP_FL_MIN_AVAILABLE_CLIENTS \
                ONEAPP_FL_CHECKPOINT_INTERVAL ONEAPP_FL_GRPC_KEEPALIVE_TIME \
                ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT; do
        _val="${!_var}"
        if ! [[ "${_val}" =~ ^[1-9][0-9]*$ ]]; then
            msg error "${_var}='${_val}' -- must be a positive integer"
            _errors=$((_errors + 1))
        fi
    done

    # Non-negative integer checks
    for _var in ONEAPP_FL_NUM_MALICIOUS; do
        _val="${!_var}"
        if ! [[ "${_val}" =~ ^[0-9]+$ ]]; then
            msg error "${_var}='${_val}' -- must be a non-negative integer"
            _errors=$((_errors + 1))
        fi
    done

    # Metrics port check
    if ! [[ "${ONEAPP_FL_METRICS_PORT}" =~ ^[0-9]+$ ]] \
       || [ "${ONEAPP_FL_METRICS_PORT}" -lt 1024 ] \
       || [ "${ONEAPP_FL_METRICS_PORT}" -gt 65535 ]; then
        msg error "ONEAPP_FL_METRICS_PORT='${ONEAPP_FL_METRICS_PORT}' -- must be 1024-65535"
        _errors=$((_errors + 1))
    fi
    if [[ "${ONEAPP_FL_METRICS_PORT}" =~ ^(9091|9092|9093)$ ]]; then
        msg error "ONEAPP_FL_METRICS_PORT='${ONEAPP_FL_METRICS_PORT}' -- conflicts with Flower ports"
        _errors=$((_errors + 1))
    fi

    # Enum checks
    case "${ONEAPP_FL_STRATEGY}" in
        FedAvg|FedProx|FedAdam|Krum|Bulyan|FedTrimmedAvg) ;;
        *) msg error "ONEAPP_FL_STRATEGY='${ONEAPP_FL_STRATEGY}' -- invalid strategy"
           _errors=$((_errors + 1)) ;;
    esac

    case "${ONEAPP_FL_ISOLATION}" in
        subprocess|process) ;;
        *) msg error "ONEAPP_FL_ISOLATION='${ONEAPP_FL_ISOLATION}' -- must be subprocess or process"
           _errors=$((_errors + 1)) ;;
    esac

    case "${ONEAPP_FL_LOG_LEVEL}" in
        DEBUG|INFO|WARNING|ERROR) ;;
        *) msg error "ONEAPP_FL_LOG_LEVEL='${ONEAPP_FL_LOG_LEVEL}' -- invalid log level"
           _errors=$((_errors + 1)) ;;
    esac

    case "${ONEAPP_FL_LOG_FORMAT}" in
        text|json) ;;
        *) msg error "ONEAPP_FL_LOG_FORMAT='${ONEAPP_FL_LOG_FORMAT}' -- must be text or json"
           _errors=$((_errors + 1)) ;;
    esac

    case "${ONEAPP_FL_TLS_ENABLED}" in
        YES|NO) ;;
        *) msg error "ONEAPP_FL_TLS_ENABLED='${ONEAPP_FL_TLS_ENABLED}' -- must be YES or NO"
           _errors=$((_errors + 1)) ;;
    esac

    case "${ONEAPP_FL_CHECKPOINT_ENABLED}" in
        YES|NO) ;;
        *) msg error "ONEAPP_FL_CHECKPOINT_ENABLED='${ONEAPP_FL_CHECKPOINT_ENABLED}' -- must be YES or NO"
           _errors=$((_errors + 1)) ;;
    esac

    case "${ONEAPP_FL_METRICS_ENABLED}" in
        YES|NO) ;;
        *) msg error "ONEAPP_FL_METRICS_ENABLED='${ONEAPP_FL_METRICS_ENABLED}' -- must be YES or NO"
           _errors=$((_errors + 1)) ;;
    esac

    # host:port format checks
    for _var in ONEAPP_FL_FLEET_API_ADDRESS ONEAPP_FL_CONTROL_API_ADDRESS; do
        _val="${!_var}"
        if ! [[ "${_val}" =~ ^[^:]+:[0-9]+$ ]]; then
            msg error "${_var}='${_val}' -- must be in host:port format"
            _errors=$((_errors + 1))
        fi
    done

    # gRPC keepalive sanity: timeout must be less than interval
    if [ "${ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT}" -ge "${ONEAPP_FL_GRPC_KEEPALIVE_TIME}" ] 2>/dev/null; then
        msg warning "ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT (${ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT}) >= ONEAPP_FL_GRPC_KEEPALIVE_TIME (${ONEAPP_FL_GRPC_KEEPALIVE_TIME})"
    fi
    if [ "${ONEAPP_FL_GRPC_KEEPALIVE_TIME}" -lt 10 ] 2>/dev/null; then
        msg warning "ONEAPP_FL_GRPC_KEEPALIVE_TIME=${ONEAPP_FL_GRPC_KEEPALIVE_TIME} -- very low keepalive interval"
    fi

    # TLS: operator certs all-or-none rule
    if [ "${ONEAPP_FL_TLS_ENABLED}" = "YES" ] && [ -n "${ONEAPP_FL_SSL_CA_CERTFILE}" ]; then
        if [ -z "${ONEAPP_FL_SSL_CERTFILE}" ] || [ -z "${ONEAPP_FL_SSL_KEYFILE}" ]; then
            msg error "Operator TLS: FL_SSL_CA_CERTFILE is set but FL_SSL_CERTFILE or FL_SSL_KEYFILE is missing (all-or-none rule)"
            _errors=$((_errors + 1))
        fi
    fi

    # Abort on any validation error
    if [ "${_errors}" -gt 0 ]; then
        msg error "Configuration validation failed with ${_errors} error(s) -- aborting"
        exit 1
    fi

    msg info "Configuration validation passed"
}

# ==========================================================================
#  HELPER: generate_tls_certs  (auto-generate CA + server certificates)
# ==========================================================================
generate_tls_certs() {
    local _vm_ip
    _vm_ip=$(hostname -I | awk '{print $1}')
    msg info "Generating TLS certificates for VM IP ${_vm_ip}"

    # Build SAN entries: base + optional extras from ONEAPP_FL_CERT_EXTRA_SAN
    local _extra_san=""
    local _san_idx=4
    if [ -n "${ONEAPP_FL_CERT_EXTRA_SAN}" ]; then
        local IFS=','
        for _entry in ${ONEAPP_FL_CERT_EXTRA_SAN}; do
            _entry=$(echo "${_entry}" | xargs)  # trim whitespace
            if [[ "${_entry}" =~ ^IP: ]]; then
                _extra_san+="IP.${_san_idx} = ${_entry#IP:}\n"
            elif [[ "${_entry}" =~ ^DNS: ]]; then
                _extra_san+="DNS.${_san_idx} = ${_entry#DNS:}\n"
            else
                msg warning "Ignoring invalid SAN entry: ${_entry} (must be IP:<addr> or DNS:<name>)"
                continue
            fi
            _san_idx=$((_san_idx + 1))
        done
    fi

    local _san_block
    _san_block="DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = ${_vm_ip}"
    if [ -n "${_extra_san}" ]; then
        _san_block+=$'\n'"$(echo -e "${_extra_san}")"
    fi

    # Step 1: CA private key
    openssl genrsa -out "${FLOWER_CERT_DIR}/ca.key" 4096 2>/dev/null

    # Step 2: Self-signed CA certificate
    openssl req -new -x509 \
        -key "${FLOWER_CERT_DIR}/ca.key" \
        -sha256 \
        -subj "/O=Flower FL/CN=Flower CA" \
        -days 365 \
        -out "${FLOWER_CERT_DIR}/ca.crt" 2>/dev/null

    # Step 3: Server private key
    openssl genrsa -out "${FLOWER_CERT_DIR}/server.key" 4096 2>/dev/null

    # Step 4: Server CSR with dynamic SAN
    openssl req -new \
        -key "${FLOWER_CERT_DIR}/server.key" \
        -out "${FLOWER_CERT_DIR}/server.csr" \
        -config <(cat <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
O = Flower FL
CN = ${_vm_ip}

[req_ext]
subjectAltName = @alt_names

[alt_names]
${_san_block}
EOF
) 2>/dev/null

    # Step 5: Sign server certificate with CA
    openssl x509 -req \
        -in "${FLOWER_CERT_DIR}/server.csr" \
        -CA "${FLOWER_CERT_DIR}/ca.crt" \
        -CAkey "${FLOWER_CERT_DIR}/ca.key" \
        -CAcreateserial \
        -out "${FLOWER_CERT_DIR}/server.pem" \
        -days 365 \
        -sha256 \
        -extfile <(cat <<EOF
[req_ext]
subjectAltName = @alt_names

[alt_names]
${_san_block}
EOF
) \
        -extensions req_ext 2>/dev/null

    # Step 6: Clean up temporary files
    rm -f "${FLOWER_CERT_DIR}/server.csr" "${FLOWER_CERT_DIR}/ca.srl"

    # Step 7: Set ownership and permissions
    chown root:root "${FLOWER_CERT_DIR}/ca.key"
    chmod 0600 "${FLOWER_CERT_DIR}/ca.key"
    chown "${FLOWER_UID}:${FLOWER_GID}" \
        "${FLOWER_CERT_DIR}/ca.crt" \
        "${FLOWER_CERT_DIR}/server.pem" \
        "${FLOWER_CERT_DIR}/server.key"
    chmod 0644 "${FLOWER_CERT_DIR}/ca.crt"
    chmod 0644 "${FLOWER_CERT_DIR}/server.pem"
    chmod 0600 "${FLOWER_CERT_DIR}/server.key"

    # Step 8: Verify certificate chain
    if openssl verify -CAfile "${FLOWER_CERT_DIR}/ca.crt" \
            "${FLOWER_CERT_DIR}/server.pem" >/dev/null 2>&1; then
        msg info "Certificate chain verified successfully"
    else
        msg error "Certificate chain verification FAILED -- aborting"
        exit 1
    fi
}

# ==========================================================================
#  HELPER: decode_operator_certs  (decode base64 operator-provided certs)
# ==========================================================================
decode_operator_certs() {
    # Decode PEM files from base64 context variables
    echo "${ONEAPP_FL_SSL_CA_CERTFILE}" | base64 -d > "${FLOWER_CERT_DIR}/ca.crt"
    msg info "CA certificate decoded from ONEAPP_FL_SSL_CA_CERTFILE"

    echo "${ONEAPP_FL_SSL_CERTFILE}" | base64 -d > "${FLOWER_CERT_DIR}/server.pem"
    msg info "Server certificate decoded from ONEAPP_FL_SSL_CERTFILE"

    echo "${ONEAPP_FL_SSL_KEYFILE}" | base64 -d > "${FLOWER_CERT_DIR}/server.key"
    msg info "Server private key decoded from ONEAPP_FL_SSL_KEYFILE"

    # Set ownership and permissions
    chown "${FLOWER_UID}:${FLOWER_GID}" \
        "${FLOWER_CERT_DIR}/ca.crt" \
        "${FLOWER_CERT_DIR}/server.pem" \
        "${FLOWER_CERT_DIR}/server.key"
    chmod 0644 "${FLOWER_CERT_DIR}/ca.crt"
    chmod 0644 "${FLOWER_CERT_DIR}/server.pem"
    chmod 0600 "${FLOWER_CERT_DIR}/server.key"

    # Validate decoded certificates
    openssl x509 -in "${FLOWER_CERT_DIR}/ca.crt" -noout 2>/dev/null || {
        msg error "ONEAPP_FL_SSL_CA_CERTFILE does not contain a valid PEM certificate"
        exit 1
    }
    openssl x509 -in "${FLOWER_CERT_DIR}/server.pem" -noout 2>/dev/null || {
        msg error "ONEAPP_FL_SSL_CERTFILE does not contain a valid PEM certificate"
        exit 1
    }
    openssl rsa -in "${FLOWER_CERT_DIR}/server.key" -check -noout 2>/dev/null || {
        msg error "ONEAPP_FL_SSL_KEYFILE does not contain a valid PEM private key"
        exit 1
    }

    # Verify chain: server cert was signed by the provided CA
    if openssl verify -CAfile "${FLOWER_CERT_DIR}/ca.crt" \
            "${FLOWER_CERT_DIR}/server.pem" >/dev/null 2>&1; then
        msg info "Operator certificate chain verified successfully"
    else
        msg error "Server certificate is not signed by the provided CA certificate"
        exit 1
    fi
}

# ==========================================================================
#  HELPER: generate_superlink_env  (write Docker env file)
# ==========================================================================
generate_superlink_env() {
    cat > "${FLOWER_ENV_FILE}" <<EOF
# Flower SuperLink environment -- generated at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
FLWR_LOG_LEVEL=${ONEAPP_FL_LOG_LEVEL}
FL_NUM_ROUNDS=${ONEAPP_FL_NUM_ROUNDS}
FL_STRATEGY=${ONEAPP_FL_STRATEGY}
FL_MIN_FIT_CLIENTS=${ONEAPP_FL_MIN_FIT_CLIENTS}
FL_MIN_EVALUATE_CLIENTS=${ONEAPP_FL_MIN_EVALUATE_CLIENTS}
FL_MIN_AVAILABLE_CLIENTS=${ONEAPP_FL_MIN_AVAILABLE_CLIENTS}
FL_PROXIMAL_MU=${ONEAPP_FL_PROXIMAL_MU}
FL_SERVER_LR=${ONEAPP_FL_SERVER_LR}
FL_CLIENT_LR=${ONEAPP_FL_CLIENT_LR}
FL_NUM_MALICIOUS=${ONEAPP_FL_NUM_MALICIOUS}
FL_TRIM_BETA=${ONEAPP_FL_TRIM_BETA}
FL_CHECKPOINT_ENABLED=${ONEAPP_FL_CHECKPOINT_ENABLED}
FL_CHECKPOINT_INTERVAL=${ONEAPP_FL_CHECKPOINT_INTERVAL}
FL_CHECKPOINT_PATH=${ONEAPP_FL_CHECKPOINT_PATH}
FL_GRPC_KEEPALIVE_TIME=${ONEAPP_FL_GRPC_KEEPALIVE_TIME}
FL_GRPC_KEEPALIVE_TIMEOUT=${ONEAPP_FL_GRPC_KEEPALIVE_TIMEOUT}
FL_METRICS_ENABLED=${ONEAPP_FL_METRICS_ENABLED}
FL_METRICS_PORT=${ONEAPP_FL_METRICS_PORT}
FL_LOG_FORMAT=${ONEAPP_FL_LOG_FORMAT}
EOF
    chmod 0640 "${FLOWER_ENV_FILE}"
    msg info "Environment file written to ${FLOWER_ENV_FILE}"
}

# ==========================================================================
#  HELPER: generate_systemd_unit  (write systemd service file)
# ==========================================================================
generate_systemd_unit() {
    # Build TLS-specific Docker and Flower flags
    local _tls_docker_flags=""
    local _tls_flower_flags=""

    if [ "${ONEAPP_FL_TLS_ENABLED}" = "YES" ]; then
        _tls_docker_flags="-v ${FLOWER_CERT_DIR}:/app/certificates:ro"
        _tls_flower_flags="--ssl-ca-certfile /app/certificates/ca.crt"
        _tls_flower_flags+=" --ssl-certfile /app/certificates/server.pem"
        _tls_flower_flags+=" --ssl-keyfile /app/certificates/server.key"
    else
        _tls_flower_flags="--insecure"
    fi

    # Build metrics port mapping
    local _metrics_port_flag=""
    if [ "${ONEAPP_FL_METRICS_ENABLED}" = "YES" ]; then
        _metrics_port_flag="-p ${ONEAPP_FL_METRICS_PORT}:${ONEAPP_FL_METRICS_PORT}"
    fi

    # Build checkpoint volume mount
    local _ckpt_docker_flags=""
    if [ "${ONEAPP_FL_CHECKPOINT_ENABLED}" = "YES" ]; then
        local _host_ckpt_dir="${FLOWER_BASE_DIR}/checkpoints"
        mkdir -p "${_host_ckpt_dir}"
        chown "${FLOWER_UID}:${FLOWER_GID}" "${_host_ckpt_dir}"
        _ckpt_docker_flags="-v ${_host_ckpt_dir}:${ONEAPP_FL_CHECKPOINT_PATH}"
    fi

    cat > "${FLOWER_SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Flower SuperLink (Federated Learning Coordinator)
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10
TimeoutStartSec=120

ExecStartPre=-/usr/bin/docker rm -f flower-superlink
ExecStart=/usr/bin/docker run --name flower-superlink --rm \\
  --env-file ${FLOWER_ENV_FILE} \\
  -p 9091:9091 -p 9092:9092 -p 9093:9093 \\
  ${_metrics_port_flag:+${_metrics_port_flag} \\}
  -v ${FLOWER_STATE_DIR}:/app/state \\
  ${_tls_docker_flags:+${_tls_docker_flags} \\}
  ${_ckpt_docker_flags:+${_ckpt_docker_flags} \\}
  flwr/superlink:${ONEAPP_FLOWER_VERSION} \\
  ${_tls_flower_flags} \\
  --isolation ${ONEAPP_FL_ISOLATION} \\
  --fleet-api-address ${ONEAPP_FL_FLEET_API_ADDRESS} \\
  --database ${ONEAPP_FL_DATABASE}
ExecStop=/usr/bin/docker stop flower-superlink

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    msg info "Systemd unit written to ${FLOWER_SYSTEMD_UNIT}"
}

# ==========================================================================
#  HELPER: wait_for_docker  (poll docker info, 60s timeout)
# ==========================================================================
wait_for_docker() {
    local _timeout=60
    local _elapsed=0

    msg info "Waiting for Docker daemon (timeout: ${_timeout}s)"
    while ! docker info >/dev/null 2>&1; do
        sleep 1
        _elapsed=$((_elapsed + 1))
        if [ "${_elapsed}" -ge "${_timeout}" ]; then
            msg error "Docker daemon not available after ${_timeout}s -- aborting"
            exit 1
        fi
    done
    msg info "Docker daemon ready (${_elapsed}s)"
}

# ==========================================================================
#  HELPER: wait_for_superlink  (poll gRPC port, 120s timeout)
# ==========================================================================
wait_for_superlink() {
    local _port
    _port=$(echo "${ONEAPP_FL_FLEET_API_ADDRESS}" | cut -d: -f2)
    local _timeout=120
    local _elapsed=0

    msg info "Waiting for SuperLink Fleet API on port ${_port} (timeout: ${_timeout}s)"
    while ! nc -z localhost "${_port}" 2>/dev/null; do
        sleep 2
        _elapsed=$((_elapsed + 2))
        if [ "${_elapsed}" -ge "${_timeout}" ]; then
            msg error "SuperLink health check timed out after ${_timeout}s"
            # Attempt to publish failure state
            publish_to_onegate "NO" "health_check_timeout" || true
            exit 1
        fi
    done
    msg info "SuperLink Fleet API is listening (${_elapsed}s)"
}

# ==========================================================================
#  HELPER: publish_to_onegate  (PUT readiness vars to OneGate)
# ==========================================================================
publish_to_onegate() {
    local _ready="${1:-YES}"
    local _error="${2:-}"
    local _vm_ip
    _vm_ip=$(hostname -I | awk '{print $1}')

    # OneGate token and VM ID from contextualization
    local _token _vmid _endpoint
    _token=$(cat /run/one-context/token.txt 2>/dev/null) || true
    _vmid=$(source /run/one-context/one_env 2>/dev/null && echo "${VMID}") || true
    _endpoint=$(source /run/one-context/one_env 2>/dev/null && echo "${ONEGATE_ENDPOINT}") || true

    if [ -z "${_token}" ] || [ -z "${_vmid}" ] || [ -z "${_endpoint}" ]; then
        msg warning "OneGate not available -- skipping readiness publication"
        return 0
    fi

    # Build data payload
    local _data="FL_READY=${_ready}"
    _data+="&FL_ENDPOINT=${_vm_ip}:${ONEAPP_FL_FLEET_API_ADDRESS##*:}"
    _data+="&FL_VERSION=${ONEAPP_FLOWER_VERSION}"
    _data+="&FL_ROLE=superlink"

    if [ -n "${_error}" ]; then
        _data+="&FL_ERROR=${_error}"
    fi

    # Publish TLS info if enabled
    if [ "${ONEAPP_FL_TLS_ENABLED}" = "YES" ] && [ "${_ready}" = "YES" ]; then
        _data+="&FL_TLS=YES"
        if [ -f "${FLOWER_CERT_DIR}/ca.crt" ]; then
            local _ca_b64
            _ca_b64=$(base64 -w0 "${FLOWER_CERT_DIR}/ca.crt")
            _data+="&FL_CA_CERT=${_ca_b64}"
        fi
    fi

    if curl -sf -X PUT "${_endpoint}/vm" \
            -H "X-ONEGATE-TOKEN: ${_token}" \
            -H "X-ONEGATE-VMID: ${_vmid}" \
            -d "${_data}" >/dev/null 2>&1; then
        msg info "Published to OneGate: FL_READY=${_ready}, FL_ENDPOINT=${_vm_ip}:${ONEAPP_FL_FLEET_API_ADDRESS##*:}"
    else
        msg warning "OneGate publication failed -- SuperNodes must use static FL_SUPERLINK_ADDRESS"
    fi
}
