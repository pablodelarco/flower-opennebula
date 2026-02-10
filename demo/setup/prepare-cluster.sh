#!/usr/bin/env bash
# Build PyTorch-enabled SuperNode image and deploy to cluster.
#
# Usage: bash demo/setup/prepare-cluster.sh
#
# Prerequisites:
#   - Docker installed locally (for building the image)
#   - SSH access to the frontend (51.158.111.100)
#   - Frontend can reach SuperNode VMs on 172.16.100.x
set -euo pipefail

IMAGE_NAME="flower-supernode-pytorch"
IMAGE_TAG="demo"
IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
ARCHIVE="/tmp/${IMAGE_NAME}-${IMAGE_TAG}.tar.gz"

FRONTEND="root@51.158.111.100"
SUPERNODE_IPS=("172.16.100.4" "172.16.100.5")

# Container/service names matching the appliance conventions
CONTAINER_NAME="flower-supernode"
SERVICE_NAME="flower-supernode.service"

echo "=== Step 1: Build PyTorch SuperNode image ==="
docker build -t "${IMAGE}" -f demo/Dockerfile.supernode demo/
echo "Image ${IMAGE} built successfully."

echo ""
echo "=== Step 2: Export image to archive ==="
docker save "${IMAGE}" | gzip > "${ARCHIVE}"
echo "Saved to ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"

echo ""
echo "=== Step 3: Upload image to frontend ==="
scp "${ARCHIVE}" "${FRONTEND}:/tmp/"
echo "Uploaded to frontend."

for IP in "${SUPERNODE_IPS[@]}"; do
    echo ""
    echo "=== Step 4: Deploy to SuperNode ${IP} ==="

    # Copy archive from frontend to SuperNode
    ssh "${FRONTEND}" "scp /tmp/$(basename "${ARCHIVE}") root@${IP}:/tmp/"

    # Load image and restart container with new image
    ssh "${FRONTEND}" "ssh root@${IP} bash -s" <<REMOTE
set -euo pipefail

echo "Loading Docker image..."
docker load < /tmp/$(basename "${ARCHIVE}")

echo "Stopping current container..."
docker stop ${CONTAINER_NAME} 2>/dev/null || true
docker rm ${CONTAINER_NAME} 2>/dev/null || true

echo "Updating systemd unit to use new image..."
# The appliance generates /etc/systemd/system/flower-supernode.service
# Update the image reference in the ExecStart line
if [ -f /etc/systemd/system/${SERVICE_NAME} ]; then
    sed -i "s|flwr/supernode:[^ ]*|${IMAGE}|g" /etc/systemd/system/${SERVICE_NAME}
    systemctl daemon-reload
    systemctl restart ${SERVICE_NAME}
    echo "Service restarted with ${IMAGE}."
else
    echo "WARNING: systemd unit not found. You may need to recreate the container manually."
    echo "Example:"
    echo "  docker run -d --name ${CONTAINER_NAME} --restart unless-stopped ${IMAGE} \\"
    echo "    --superlink 172.16.100.3:9092 --isolation subprocess"
fi

echo "Verifying..."
docker ps --filter name=${CONTAINER_NAME} --format '{{.Image}} {{.Status}}'

echo "Cleaning up archive..."
rm -f /tmp/$(basename "${ARCHIVE}")
REMOTE

    echo "SuperNode ${IP} updated."
done

echo ""
echo "=== Step 5: Cleanup ==="
ssh "${FRONTEND}" "rm -f /tmp/$(basename "${ARCHIVE}")"
rm -f "${ARCHIVE}"
echo "Temporary files cleaned up."

echo ""
echo "=== Done ==="
echo "Both SuperNodes now run ${IMAGE}."
echo "Run 'bash demo/setup/verify-cluster.sh' to confirm everything is healthy."
