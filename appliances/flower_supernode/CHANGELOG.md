# Changelog

All notable changes to the Flower SuperNode appliance will be documented in this file.

## [1.25.0-1.0.0] - 2026-06-18

### Added

- Standalone Flower SuperNode appliance, split out of `flower_service` so the
  image is built and certified independently by the marketplace pipeline.
- Ubuntu 24.04 + Docker running a Flower client with a pre-baked PyTorch
  framework image (TensorFlow / scikit-learn built on demand). Connects out to
  a SuperLink Fleet API; no inbound ports are exposed.

### Fixed

- SuperNode now self-heals after a SuperLink restart. The container no longer
  carries a Docker `--restart` policy (which fought the systemd `docker start -a`
  unit and left the node permanently dead after a SuperLink bounce), and the
  unit uses `Restart=always` instead of `Restart=on-failure` so a clean exit
  caused by the coordinator restarting also triggers a rejoin. Verified on a
  live 2-node service: a node left dead by the old policy stayed down with no
  recovery.
