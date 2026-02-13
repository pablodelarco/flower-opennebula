# Flower Federated Learning Service

The Flower FL Service provides a privacy-preserving [Flower](https://flower.ai/) federated learning cluster deployed as an OpenNebula service, orchestrated by [OneFlow](https://docs.opennebula.io/stable/management_and_operations/multivm_service_management/overview.html).

The service deploys one SuperLink coordinator and N SuperNode training clients. The SuperLink boots first, publishes its endpoint to OneGate, and reports READY. SuperNodes then start, auto-discover the SuperLink, and connect to the Fleet API. Raw training data never leaves the SuperNode VMs -- only model weights are transmitted.

The following roles are defined:

* **SuperLink**: Flower coordinator that manages federated training rounds, aggregates model updates, and exposes the Fleet API for SuperNode connections. Supports 6 aggregation strategies: FedAvg, FedProx, FedAdam, Krum, Bulyan, and FedTrimmedAvg.
* **SuperNode**: Flower training client with three pre-built ML framework containers -- PyTorch 2.6.0, TensorFlow 2.18.1, and scikit-learn. Set `ONEAPP_FL_FRAMEWORK` at deployment time to select which framework boots.

## Downloading and Deploying the Service

1. Download the `Service Flower FL 1.25.0` appliance from the OpenNebula Community Marketplace:

   ```shell
   $ onemarketapp export 'Service Flower FL 1.25.0' 'Service Flower FL' --datastore default
   ```

   This automatically imports the dependent VM templates and OS disk images.

2. Adjust the service template to your needs. You can set the CPU, RAM, and disk size for each role's VM template in Sunstone or via the CLI.

3. Configure networks for the service template by selecting an existing private network that all FL cluster VMs will share.

4. Configure the service parameters:

   | Parameter | Description | Default |
   |-----------|-------------|---------|
   | `ONEAPP_FL_ML_FRAMEWORK` | ML framework: `pytorch`, `tensorflow`, `sklearn` | `pytorch` |
   | `ONEAPP_FL_NUM_ROUNDS` | Number of federated training rounds | `3` |
   | `ONEAPP_FL_AGG_STRATEGY` | Aggregation strategy: `FedAvg`, `FedProx`, `FedAdam` | `FedAvg` |
   | `ONEAPP_FL_MIN_AVAILABLE_CLIENTS` | Minimum SuperNodes required to start a round | `2` |
   | `ONEAPP_FL_TLS_ENABLED` | Encrypt SuperLink-SuperNode communication | `NO` |
   | `ONEAPP_FL_GPU_ENABLED` | Enable GPU passthrough for training | `NO` |

5. Instantiate the service:

   ```shell
   $ oneflow-template instantiate 'Service Flower FL'
   ```

6. The SuperLink deploys first and reports READY via OneGate. SuperNodes then auto-deploy, discover the SuperLink endpoint, and begin training.

## Requirements

* OpenNebula version: >= 6.8
* [OneFlow](https://docs.opennebula.io/stable/management_and_operations/multivm_service_management/overview.html) and [OneGate](https://docs.opennebula.io/stable/management_and_operations/multivm_service_management/onegate_usage.html) for multi-VM orchestration and service discovery.

## Logo

> **TODO**: Add `flower.png` (512x512 PNG) to the marketplace `logos/` directory. The YAML files reference `logo: flower.png`.
