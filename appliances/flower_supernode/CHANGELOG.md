# Changelog

All notable changes to the Flower SuperNode appliance will be documented in this file.

## [1.25.0-1.0.0] - 2026-06-18

### Added

- Standalone Flower SuperNode appliance, split out of `flower_service` so the
  image is built and certified independently by the marketplace pipeline.
- Ubuntu 24.04 + Docker running a Flower client with a pre-baked PyTorch
  framework image (TensorFlow / scikit-learn built on demand). Connects out to
  a SuperLink Fleet API; no inbound ports are exposed.
