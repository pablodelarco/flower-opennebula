# Changelog

All notable changes to the Flower SuperLink appliance will be documented in this file.

## [1.25.0-1.0.0] - 2026-06-18

### Added

- Standalone Flower SuperLink appliance, split out of `flower_service` so the
  image is built and certified independently by the marketplace pipeline.
- Ubuntu 24.04 + Docker running `flwr/superlink` 1.25.0, with TLS enabled by
  default and the Fleet API published on the VM's primary NIC (port 9092).
