# Flower Federated Learning Service

The Flower FL Service provides a privacy-preserving [Flower](https://flower.ai/) federated learning cluster deployed as an OpenNebula service, orchestrated by [OneFlow](https://docs.opennebula.io/stable/management_and_operations/multivm_service_management/overview.html).

The service deploys one SuperLink coordinator and N SuperNode training clients. The SuperLink boots first, publishes its endpoint to OneGate, and reports READY. SuperNodes then start, auto-discover the SuperLink, and connect to the Fleet API. Raw training data never leaves the SuperNode VMs -- only model weights are transmitted.

The following roles are defined:

* **SuperLink**: Flower coordinator that aggregates model updates and exposes the Fleet API for SuperNode connections. The aggregation strategy (FedAvg, FedProx, FedAdam and others) and the number of rounds are defined in the Flower App Bundle you submit with `flwr run`, not on the appliance.
* **SuperNode**: Flower training client with PyTorch 2.5.1 (CPU) pre-baked. TensorFlow 2.18.1 and scikit-learn are built automatically on first boot when selected. Set `ONEAPP_FL_FRAMEWORK` at deployment time to select the framework.

## Security

This appliance is hardened by default so it cannot be abused (for example as a spam relay) if a workload is ever compromised:

* **TLS is on by default** between the SuperLink and SuperNodes. The SuperLink auto-generates a CA and server certificate and publishes the CA over OneGate; SuperNodes retrieve and trust it automatically. No manual certificate handling is required.
* **No Flower port is exposed on `0.0.0.0`.** The Fleet API (9092) is bound to the private FL network, and the Control API (9093) is bound to `127.0.0.1` only. Because the Control API executes the code you submit, reach it through an SSH tunnel: `ssh -L 9093:localhost:9093 root@<superlink-ip>`.
* **A default-deny host firewall** (UFW + `DOCKER-USER` rules) allows only SSH inbound and restricts the FL ports to the private subnet.
* **Outbound SMTP (ports 25/465/587) is blocked** on every VM, so a node can never send mail.

## Downloading and Deploying the Service

1. Download the `Service Flower FL 1.25.0` appliance from the OpenNebula Community Marketplace:

   ```shell
   $ onemarketapp export 'Service Flower FL 1.25.0' 'Service Flower FL' --datastore default
   ```

   This automatically imports the dependent VM templates and OS disk images.

2. Adjust the service template to your needs. You can set the CPU, RAM, and disk size for each role's VM template in FireEdge or via the CLI. SuperNodes default to 8 GB RAM so PyTorch training has headroom; lighter workloads (for example scikit-learn) run comfortably in less.

3. Configure networks for the service template by selecting an existing private network that all FL cluster VMs will share.

4. Configure the service parameters:

   | Parameter | Description | Default |
   |-----------|-------------|---------|
   | `ONEAPP_FL_FRAMEWORK` | ML framework: `pytorch`, `tensorflow`, `sklearn` | `pytorch` |
   | `ONEAPP_FL_TLS_ENABLED` | Encrypt SuperLink-SuperNode communication | `YES` |

   The aggregation strategy and the number of training rounds are **not** appliance settings: they are part of the Flower App Bundle you submit with `flwr run --run-config ...`. The stock SuperLink does not read them from the environment.

5. Instantiate the service:

   ```shell
   $ oneflow-template instantiate 'Service Flower FL'
   ```

6. The SuperLink deploys first and reports READY via OneGate. SuperNodes then auto-deploy, discover the SuperLink endpoint, and connect.

## After Deployment

Once the service is RUNNING, the cluster is idle and waiting for a Flower Application Bundle (FAB). You push training code from your local machine using `flwr run`, and the SuperLink distributes it to all SuperNodes. See the [main project README](../../README.md#step-3-run-federated-training) for a full walkthrough of running your first training, using custom datasets, and retrieving trained models.

## Requirements

* OpenNebula version: >= 6.8
* [OneFlow](https://docs.opennebula.io/stable/management_and_operations/multivm_service_management/overview.html) and [OneGate](https://docs.opennebula.io/stable/management_and_operations/multivm_service_management/onegate_usage.html) for multi-VM orchestration and service discovery.

## Components

| Component | Version | Notes |
|-----------|---------|-------|
| Flower    | 1.25.0  | `flwr/superlink` container; `flwr[simulation]` in framework images |
| PyTorch   | 2.5.1 (CPU) | Pre-baked into the SuperNode image |
| TensorFlow | 2.18.1 | Built on first boot when selected |
| scikit-learn | 1.5.2 | Built on first boot when selected |
| Ubuntu    | 24.04 LTS | |
| Docker CE | 27+    | |
