# Changelog

All notable changes to the Flower SuperLink appliance will be documented in this file.

## [1.31.0-1.0.0] - 2026-06-18

### Added

- Standalone Flower SuperLink appliance, split out of `flower_service` so the
  image is built and certified independently by the marketplace pipeline.
- Ubuntu 24.04 + Docker running `flwr/superlink` 1.31.0, with TLS enabled by
  default and the Fleet API published on the VM's primary NIC (port 9092).

### Fixed

- Systemd unit uses `Restart=always` instead of `Restart=on-failure` so the
  coordinator respawns even on a clean exit (a downed SuperLink otherwise takes
  the whole federation down). The existing `ExecStartPre=docker rm -f` keeps the
  always-restart name-conflict safe.
