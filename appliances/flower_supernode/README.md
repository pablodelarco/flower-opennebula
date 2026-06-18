# Flower SuperNode

Standalone OpenNebula appliance for the [Flower](https://flower.ai/) **SuperNode**, a federated-learning client that connects to a SuperLink and runs the local training workload. Ubuntu 24.04 + Docker, with the selected ML framework image (PyTorch by default; TensorFlow / scikit-learn built on demand).

This same image is the SuperNode role of the **Flower FL** OneFlow service (see `appliances/flower_service`). It is split into its own appliance directory so the image is built and certified independently by the marketplace pipeline. In normal use the SuperNode is deployed as part of the OneFlow service, where the SuperLink address (and CA certificate) are discovered automatically via OneGate.

## Quick start

1. Instantiate the appliance and set `ONEAPP_FL_SUPERLINK_ADDRESS` to your SuperLink's Fleet API (`<superlink-ip>:9092`), or deploy it through the Flower FL OneFlow service for automatic discovery.
2. The SuperNode connects to the SuperLink on boot and waits for training rounds.
3. Read status: `cat /etc/one-appliance/config`.

## Contextualization

| Variable | Default | Description |
|----------|---------|-------------|
| `ONEAPP_FL_FRAMEWORK` | `pytorch` | ML framework (`pytorch` / `tensorflow` / `sklearn`) |
| `ONEAPP_FL_SUPERLINK_ADDRESS` | (OneGate discovery) | SuperLink Fleet API address (`host:port`) |
| `ONEAPP_FL_TLS_ENABLED` | `YES` | Verify the SuperLink TLS certificate |
| `ONEAPP_FL_NODE_CONFIG` | (empty) | Space-separated `key=value` node config |
| `ONEAPP_FL_MAX_RETRIES` | `0` | Max reconnection attempts (`0` = unlimited) |
| `ONEAPP_FL_LOG_LEVEL` | `INFO` | Log verbosity (`DEBUG`/`INFO`/`WARNING`/`ERROR`) |

The SuperNode dials out to the SuperLink and exposes no inbound ports.
