#!/usr/bin/env bash
# Pre-flight checks for the Flower FL demo cluster.
#
# Usage: bash demo/setup/verify-cluster.sh
#
# Run this AFTER prepare-cluster.sh and BEFORE 'flwr run'.
# Expects an active SSH tunnel: ssh -L 9093:172.16.100.3:9093 root@51.158.111.100
set -euo pipefail

FRONTEND="root@51.158.111.100"
SUPERLINK_IP="172.16.100.3"
SUPERNODE_IPS=("172.16.100.4" "172.16.100.5")

PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "  PASS  ${name}"
        ((PASS++))
    else
        echo "  FAIL  ${name}"
        ((FAIL++))
    fi
}

echo "Flower FL Demo — Cluster Verification"
echo "======================================"
echo ""

# --- Local checks ---
echo "[Local Machine]"
check "SSH tunnel active (127.0.0.1:9093)" nc -z 127.0.0.1 9093
check "flwr CLI installed" command -v flwr
echo ""

# --- SuperLink checks ---
echo "[SuperLink — ${SUPERLINK_IP}]"
check "SSH reachable" ssh -o ConnectTimeout=5 "${FRONTEND}" "ssh -o ConnectTimeout=5 root@${SUPERLINK_IP} true"
check "Docker running" ssh "${FRONTEND}" "ssh root@${SUPERLINK_IP} docker ps -q"
check "SuperLink container up" ssh "${FRONTEND}" "ssh root@${SUPERLINK_IP} docker ps --filter name=flower-superlink --format '{{.Status}}' | grep -q Up"
echo ""

# --- SuperNode checks ---
for IP in "${SUPERNODE_IPS[@]}"; do
    echo "[SuperNode — ${IP}]"
    check "SSH reachable" ssh -o ConnectTimeout=5 "${FRONTEND}" "ssh -o ConnectTimeout=5 root@${IP} true"
    check "Docker running" ssh "${FRONTEND}" "ssh root@${IP} docker ps -q"
    check "SuperNode container up" ssh "${FRONTEND}" "ssh root@${IP} docker ps --filter name=flower-supernode --format '{{.Status}}' | grep -q Up"
    check "PyTorch importable" ssh "${FRONTEND}" "ssh root@${IP} docker exec flower-supernode python -c 'import torch; print(torch.__version__)'"
    check "flwr-datasets importable" ssh "${FRONTEND}" "ssh root@${IP} docker exec flower-supernode python -c 'import flwr_datasets'"
    echo ""
done

# --- Summary ---
echo "======================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "Fix the failures above before running 'flwr run'."
    exit 1
else
    echo ""
    echo "All checks passed. Ready to run:"
    echo "  cd demo && flwr run . opennebula"
fi
