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
TLS is enabled by default, the Control API is bound to localhost, and a
default-deny firewall blocks outbound SMTP. The aggregation strategy and round
count come from the Flower App Bundle submitted with flwr run.'
ONE_SERVICE_RECONFIGURABLE=true

# --------------------------------------------------------------------------
# ONE_SERVICE_PARAMS -- flat array, 4-element stride:
#   'VARNAME' 'lifecycle_step' 'Description' 'default_value'
#
# All variables are bound to the 'configure' step so they are re-read on
# every VM boot / reconfigure cycle.
# --------------------------------------------------------------------------
ONE_SERVICE_PARAMS=(
    # --- Core configuration ---
    # NOTE on FL training behaviour: the aggregation strategy, number of rounds,
    # client minimums and checkpointing are properties of the Flower App Bundle
    # (FAB) that you submit at run time with `flwr run --run-config ...`, NOT of
    # the SuperLink process. The stock flwr/superlink image ignores any such
    # environment variables, so they are deliberately NOT exposed here to avoid
    # advertising knobs that have no effect. See README "Running training".
    'ONEAPP_FLOWER_VERSION'           'configure' 'Flower Docker image version tag'                        '1.25.0'
    'ONEAPP_FL_ISOLATION'             'configure' 'App execution isolation mode (subprocess|process)'      'subprocess'
    'ONEAPP_FL_DATABASE'              'configure' 'Database path for state persistence'                    'state/state.db'
    'ONEAPP_FL_LOG_LEVEL'             'configure' 'Log verbosity (DEBUG|INFO|WARNING|ERROR)'               'INFO'

    # --- TLS configuration (secure by default) ---
    'ONEAPP_FL_TLS_ENABLED'           'configure' 'Enable TLS encryption (YES|NO)'                         'YES'
)

# --------------------------------------------------------------------------
# Default value assignments
# --------------------------------------------------------------------------
ONEAPP_FLOWER_VERSION="${ONEAPP_FLOWER_VERSION:-1.25.0}"
ONEAPP_FL_ISOLATION="${ONEAPP_FL_ISOLATION:-subprocess}"
ONEAPP_FL_DATABASE="${ONEAPP_FL_DATABASE:-state/state.db}"
ONEAPP_FL_LOG_LEVEL="${ONEAPP_FL_LOG_LEVEL:-INFO}"
ONEAPP_FL_TLS_ENABLED="${ONEAPP_FL_TLS_ENABLED:-YES}"

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

    # 3. Install OpenSSL (TLS generation), jq (JSON parsing), netcat (health
    #    checks) and the firewall stack (ufw + iptables) used by the boot-time
    #    hardening in service_configure. Rules are re-applied on every boot, so
    #    iptables-persistent is intentionally not required.
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq openssl jq netcat-openbsd ufw iptables >/dev/null

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
        msg info "TLS enabled -- auto-generating CA and server certificates"
        generate_tls_certs
    else
        msg info "TLS disabled -- using insecure mode"
    fi

    # 4. Generate Docker environment file
    generate_superlink_env

    # 5. Generate systemd unit file
    generate_systemd_unit

    # 6. Harden the host firewall (default-deny inbound, restrict the FL ports
    #    to the private network, block outbound SMTP). Re-applied every boot
    #    because ONE_SERVICE_RECONFIGURABLE=true. This is the load-bearing
    #    control that prevents the appliance from being conscripted into spam.
    harden_firewall

    # 7. Write service report
    local _vm_ip
    _vm_ip=$(get_primary_ip)
    local _report=""
    _report+="Flower SuperLink ${ONEAPP_FLOWER_VERSION}\n"
    _report+="Fleet API (SuperNodes): ${_vm_ip}:9092\n"
    _report+="Control API: 127.0.0.1:9093 (operator only -- reach via 'ssh -L 9093:localhost:9093 root@${_vm_ip}')\n"
    _report+="TLS: ${ONEAPP_FL_TLS_ENABLED}\n"
    _report+="Firewall: default-deny inbound, FL ports restricted to ${FL_PRIVATE_CIDR:-private subnet}, outbound SMTP blocked\n"
    _report+="Submit training: push a Flower App Bundle with 'flwr run' against the Control API\n"
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
  ONEAPP_FL_TLS_ENABLED           Enable TLS (default: YES)
  ONEAPP_FL_ISOLATION             App isolation: subprocess|process (default: subprocess)

The aggregation strategy, number of rounds and client minimums are NOT set
here: they are properties of the Flower App Bundle you submit at run time with
'flwr run --run-config ...'. The stock SuperLink image ignores such variables.

Ports (none are published on 0.0.0.0):
  9091  ServerAppIo  (container-internal only, not published)
  9092  Fleet API    (bound to the private NIC; SuperNode connections)
  9093  Control API  (bound to 127.0.0.1; reach via SSH tunnel, executes code)

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
    # No-op: the one-appliance framework calls cleanup between lifecycle stages,
    # but we must not destroy the container/service that bootstrap just started.
    # Container lifecycle is managed by systemd (Restart=on-failure).
    :
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
        | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
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

    # Enum checks
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

    case "${ONEAPP_FL_TLS_ENABLED}" in
        YES|NO) ;;
        *) msg error "ONEAPP_FL_TLS_ENABLED='${ONEAPP_FL_TLS_ENABLED}' -- must be YES or NO"
           _errors=$((_errors + 1)) ;;
    esac

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
    _vm_ip=$(get_primary_ip)

    # Persistence: ONE_SERVICE_RECONFIGURABLE=true re-runs configure on every
    # boot. Regenerating the CA each boot would break SuperNodes that already
    # pinned the previous CA, so reuse existing certs when they are still valid
    # and cover the current VM IP.
    if [ -f "${FLOWER_CERT_DIR}/ca.crt" ] && [ -f "${FLOWER_CERT_DIR}/server.pem" ] \
       && [ -f "${FLOWER_CERT_DIR}/server.key" ] \
       && openssl verify -CAfile "${FLOWER_CERT_DIR}/ca.crt" "${FLOWER_CERT_DIR}/server.pem" >/dev/null 2>&1 \
       && openssl x509 -in "${FLOWER_CERT_DIR}/server.pem" -noout -checkend 86400 >/dev/null 2>&1 \
       && openssl x509 -in "${FLOWER_CERT_DIR}/server.pem" -noout -text 2>/dev/null | grep -qF "${_vm_ip}"; then
        msg info "Reusing existing valid TLS certificates (cover ${_vm_ip})"
        return 0
    fi

    msg info "Generating TLS certificates for VM IP ${_vm_ip}"

    local _san_block
    _san_block="DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = ${_vm_ip}"

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
#  HELPER: generate_superlink_env  (write Docker env file)
# ==========================================================================
generate_superlink_env() {
    # Only FLWR_LOG_LEVEL is read by the stock flwr/superlink container. The
    # former FL_STRATEGY/FL_NUM_ROUNDS/FL_MIN_*/FL_CHECKPOINT_* variables were
    # never consumed by the image (those are Flower App Bundle run-config values
    # chosen at `flwr run` time), so they are intentionally not written here.
    cat > "${FLOWER_ENV_FILE}" <<EOF
# Flower SuperLink environment -- generated at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
FLWR_LOG_LEVEL=${ONEAPP_FL_LOG_LEVEL}
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

    # Port publishing. SECURITY: never publish on 0.0.0.0.
    #   9091 ServerAppIo  -- container-internal only, NOT published
    #   9092 Fleet API    -- bound to the private NIC so SuperNodes (same FL
    #                        network) can reach it; the firewall additionally
    #                        restricts it to the FL subnet
    #   9093 Control API  -- bound to 127.0.0.1 ONLY; executes submitted code,
    #                        so operators reach it through an SSH tunnel
    local _vm_ip
    _vm_ip=$(get_primary_ip)
    # Fail closed: if the primary IP cannot be determined, bind to loopback
    # rather than risk an unintended 0.0.0.0 bind. The firewall is a backstop.
    [ -z "${_vm_ip}" ] && _vm_ip="127.0.0.1"

    # Build ExecStart command as an array to avoid empty-line continuation bugs
    local _exec_parts=()
    _exec_parts+=("/usr/bin/docker run --name flower-superlink")
    _exec_parts+=("  --env-file ${FLOWER_ENV_FILE}")
    _exec_parts+=("  -p ${_vm_ip}:9092:9092 -p 127.0.0.1:9093:9093")
    _exec_parts+=("  -v ${FLOWER_STATE_DIR}:/app/state")
    [ -n "${_tls_docker_flags}" ]   && _exec_parts+=("  ${_tls_docker_flags}")
    _exec_parts+=("  flwr/superlink:${ONEAPP_FLOWER_VERSION}")
    _exec_parts+=("  ${_tls_flower_flags}")
    _exec_parts+=("  --isolation ${ONEAPP_FL_ISOLATION}")
    # Pin the in-container Fleet API bind to 9092 so the host publish
    # (9092:9092) maps correctly.
    _exec_parts+=("  --fleet-api-address 0.0.0.0:9092")
    _exec_parts+=("  --database ${ONEAPP_FL_DATABASE}")

    # Join with backslash-newline continuations
    local _exec_start
    _exec_start=$(printf ' \\\n%s' "${_exec_parts[@]}")
    _exec_start="ExecStart=${_exec_start:3}"  # strip leading ' \\\n' (3 chars: space, backslash, newline)

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
${_exec_start}
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
    local _port _host
    _port="9092"
    # The Fleet API is published on the private NIC (not localhost), so probe
    # there.
    _host=$(get_primary_ip)
    local _timeout=120
    local _elapsed=0

    msg info "Waiting for SuperLink Fleet API on ${_host}:${_port} (timeout: ${_timeout}s)"
    while ! nc -z "${_host}" "${_port}" 2>/dev/null; do
        sleep 2
        _elapsed=$((_elapsed + 2))
        if [ "${_elapsed}" -ge "${_timeout}" ]; then
            # Non-fatal: do NOT abort the boot. Aborting would stop the
            # one-apps framework from writing the ready MOTD and would block the
            # OneFlow ready_status_gate, leaving the VM unreachable for debugging.
            # Report the degraded state and let the service stay up so systemd
            # (Restart=on-failure) and the operator can recover.
            msg warning "SuperLink Fleet API not listening after ${_timeout}s -- continuing; check 'journalctl -u flower-superlink'"
            publish_to_onegate "NO" "health_check_timeout" || true
            return 0
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
    _vm_ip=$(get_primary_ip)

    # Check onegate CLI is available
    if ! command -v onegate >/dev/null 2>&1; then
        msg warning "OneGate CLI not available -- skipping readiness publication"
        return 0
    fi

    # Publish each attribute individually via onegate CLI (reliable encoding)
    local _fl_endpoint="${_vm_ip}:9092"
    local _failed=0

    onegate vm update --data "FL_READY=${_ready}" 2>/dev/null || _failed=1
    onegate vm update --data "FL_ENDPOINT=${_fl_endpoint}" 2>/dev/null || _failed=1
    onegate vm update --data "FL_VERSION=${ONEAPP_FLOWER_VERSION}" 2>/dev/null || _failed=1
    onegate vm update --data "FL_ROLE=superlink" 2>/dev/null || _failed=1

    if [ -n "${_error}" ]; then
        onegate vm update --data "FL_ERROR=${_error}" 2>/dev/null || _failed=1
    fi

    # Publish TLS info if enabled
    if [ "${ONEAPP_FL_TLS_ENABLED}" = "YES" ] && [ "${_ready}" = "YES" ]; then
        onegate vm update --data "FL_TLS=YES" 2>/dev/null || _failed=1
        if [ -f "${FLOWER_CERT_DIR}/ca.crt" ]; then
            local _ca_b64
            _ca_b64=$(base64 -w0 "${FLOWER_CERT_DIR}/ca.crt")
            onegate vm update --data "FL_CA_CERT=${_ca_b64}" 2>/dev/null || _failed=1
        fi
    fi

    if [ "${_failed}" -eq 0 ]; then
        msg info "Published to OneGate: FL_READY=${_ready}, FL_ENDPOINT=${_fl_endpoint}"
    else
        msg warning "OneGate publication failed -- SuperNodes must use static FL_SUPERLINK_ADDRESS"
    fi
}

# ==========================================================================
#  HELPER: get_primary_ip  (first non-loopback IPv4 address)
# ==========================================================================
get_primary_ip() {
    local _ip
    _ip=$(ip -o -f inet route show to default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "${_ip}" ]; then
        ip -o -f inet addr show dev "${_ip}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
        return 0
    fi
    hostname -I 2>/dev/null | awk '{print $1}'
}

# ==========================================================================
#  HELPER: get_primary_cidr  (connected subnet of the primary interface)
# ==========================================================================
get_primary_cidr() {
    # Anchor to the default-route interface. Taking the first link-scope route
    # is unsafe once Docker is up: docker0's 172.17.0.0/16 can sort ahead of the
    # real FL subnet, which would scope the firewall to the wrong network.
    local _if _cidr
    _if=$(ip -o -f inet route show to default 2>/dev/null | awk '{print $5; exit}')
    [ -n "${_if}" ] && _cidr=$(ip -o -f inet route show scope link dev "${_if}" 2>/dev/null | awk '{print $1; exit}')
    echo "${_cidr}"
}

# ==========================================================================
#  HELPER: harden_firewall  (default-deny inbound + FL-port scoping + SMTP
#  egress block). Idempotent; re-applied on every configure/boot. This is the
#  control that prevents the appliance from being abused as a spam relay even
#  if a workload is compromised. All commands are best-effort so a firewall
#  hiccup never aborts the boot.
# ==========================================================================
harden_firewall() {
    msg info "Hardening host firewall (default-deny inbound, SMTP egress block)"

    FL_PRIVATE_CIDR=$(get_primary_cidr)
    [ -z "${FL_PRIVATE_CIDR}" ] && FL_PRIVATE_CIDR="$(get_primary_ip)/24"
    local _ext_if
    _ext_if=$(ip -o -f inet route show to default 2>/dev/null | awk '{print $5; exit}')

    # --- Host-level inbound policy via UFW (covers host services, e.g. SSH) ---
    if command -v ufw >/dev/null 2>&1; then
        ufw --force reset      >/dev/null 2>&1 || true
        ufw default deny incoming  >/dev/null 2>&1 || true
        ufw default allow outgoing >/dev/null 2>&1 || true
        ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1 || true
        ufw logging low        >/dev/null 2>&1 || true
        ufw --force enable     >/dev/null 2>&1 || true
    fi

    # --- Container-published ports bypass UFW (Docker DNATs before INPUT), so
    #     they must be filtered in the DOCKER-USER chain. Restrict the Flower
    #     ports to the FL private subnet; everything else is dropped. ---
    if command -v iptables >/dev/null 2>&1; then
        iptables -L DOCKER-USER >/dev/null 2>&1 || iptables -N DOCKER-USER 2>/dev/null || true

        # Block all outbound SMTP (the direct spam vector) for both host and
        # container traffic. The appliance never sends mail.
        iptables -C OUTPUT -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null \
            || iptables -A OUTPUT -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null || true
        iptables -C DOCKER-USER -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null \
            || iptables -I DOCKER-USER -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null || true

        # Restrict the published Flower ports to the FL private subnet, but only
        # for traffic arriving on the EXTERNAL interface. The -i match is
        # essential: with Docker's userland-proxy, loopback/bridge-sourced
        # traffic (e.g. the 127.0.0.1-published Control API reached over an SSH
        # tunnel) appears with a non-FL source and would otherwise be dropped.
        if [ -n "${_ext_if}" ]; then
            iptables -C DOCKER-USER -i "${_ext_if}" ! -s "${FL_PRIVATE_CIDR}" -p tcp -m multiport --dports 9091,9092,9093,9101,9400 -j DROP 2>/dev/null \
                || iptables -I DOCKER-USER -i "${_ext_if}" ! -s "${FL_PRIVATE_CIDR}" -p tcp -m multiport --dports 9091,9092,9093,9101,9400 -j DROP 2>/dev/null || true
        fi
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C OUTPUT -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null \
            || ip6tables -A OUTPUT -p tcp -m multiport --dports 25,465,587 -j REJECT 2>/dev/null || true
    fi

    # Persist so the rules survive a reboot even before configure re-runs.
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    msg info "Firewall hardened (FL ports limited to ${FL_PRIVATE_CIDR}, SMTP egress blocked)"
}
