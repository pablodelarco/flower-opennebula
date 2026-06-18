# Flower SuperLink

Standalone OpenNebula appliance for the [Flower](https://flower.ai/) **SuperLink**, the central coordinator of a Flower federated-learning deployment. Ubuntu 24.04 + Docker running `flwr/superlink`, with TLS and a Fleet API published for SuperNodes.

This same image is the SuperLink role of the **Flower FL** OneFlow service (see `appliances/flower_service`). It is split into its own appliance directory so the image is built and certified independently by the marketplace pipeline.

## Quick start

1. Instantiate the appliance (4 vCPU / 4 GB RAM is sufficient).
2. The SuperLink starts automatically on first boot.
3. Read the connection details (Fleet API address and CA certificate): `cat /etc/one-appliance/config`.
4. Point SuperNodes at the Fleet API at `<vm-ip>:9092`.

## Contextualization

| Variable | Default | Description |
|----------|---------|-------------|
| `ONEAPP_FLOWER_VERSION` | `1.25.0` | `flwr/superlink` Docker image tag |
| `ONEAPP_FL_TLS_ENABLED` | `YES` | Enable TLS (a self-signed CA is generated on boot) |
| `ONEAPP_FL_LOG_LEVEL` | `INFO` | Log verbosity (`DEBUG`/`INFO`/`WARNING`/`ERROR`) |

## Ports

| Port | Bind | Purpose |
|------|------|---------|
| 9092 | NIC IP | Fleet API (SuperNodes connect here) |
| 9093 | 127.0.0.1 | Control API (reach via SSH tunnel only) |
