# Changelog

All notable changes to this appliance will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.31.0-1.0.0] - 2026-06-15

### Added

- Initial release of the Flower Federated Learning service for OpenNebula
- SuperLink coordinator and SuperNode training client running Flower 1.31.0
  in Docker, managed by systemd. The aggregation strategy and round count are
  chosen per run in the Flower App Bundle submitted with `flwr run`
- OneFlow service template with auto-scaling (2-10 SuperNodes) and OneGate
  service discovery
- SuperNode ships PyTorch 2.5.1 (CPU) pre-baked; TensorFlow 2.18.1 and
  scikit-learn 1.5.2 are built automatically on first boot when selected,
  keeping the base image small enough for marketplace certification. SuperNodes
  default to 8 GB RAM to give PyTorch training enough headroom

### Security

- TLS enabled by default between SuperLink and SuperNodes; the SuperLink
  auto-generates a CA and server certificate and distributes the CA over
  OneGate, so TLS is zero-config
- No Flower port is published on `0.0.0.0`: the Fleet API binds the private
  NIC and the Control API binds `127.0.0.1` (reachable via SSH tunnel only),
  closing the unauthenticated remote-code-execution surface
- Default-deny host firewall (UFW + `DOCKER-USER` rules) restricting the FL
  ports to the private subnet, plus an outbound SMTP (25/465/587) block so a
  compromised node cannot send mail
- SuperNode container is started from an argument array instead of `eval`,
  removing a root command-injection path via `ONEAPP_FL_NODE_CONFIG`
