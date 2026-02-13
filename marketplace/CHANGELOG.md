# Changelog

All notable changes to this appliance will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.25.0-1.0.0] - 2026-02-11

### Added

- Initial release of Flower Federated Learning service for OpenNebula
- SuperLink coordinator with 6 aggregation strategies (FedAvg, FedProx, FedAdam, Krum, Bulyan, FedTrimmedAvg)
- SuperNode with PyTorch 2.6.0, TensorFlow 2.18.1, and scikit-learn pre-built containers
- OneFlow service template with auto-scaling (2-10 SuperNodes)
- Automatic service discovery via OneGate
- Optional TLS encryption between SuperLink and SuperNodes
- Optional GPU passthrough for accelerated training
- Model checkpointing support
