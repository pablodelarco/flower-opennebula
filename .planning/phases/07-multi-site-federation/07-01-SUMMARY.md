---
phase: 07-multi-site-federation
plan: 01
subsystem: infra
tags: [opennebula, wireguard, grpc-keepalive, tls, multi-site, federation, oneflow]

# Dependency graph
requires:
  - phase: 02-security-certificate-automation
    provides: TLS certificate lifecycle and static FL_SSL_CA_CERTFILE provisioning path
  - phase: 04-single-site-orchestration
    provides: OneFlow service template structure and ready_status_gate pattern
provides:
  - Complete multi-site federation specification (spec/12-multi-site-federation.md)
  - 3-zone reference deployment topology with per-zone OneFlow service templates
  - Two cross-zone networking options (WireGuard VPN and direct public IP)
  - gRPC keepalive configuration for WAN resilience
  - TLS certificate trust distribution across zones
  - Three new CONTEXT variables (FL_GRPC_KEEPALIVE_TIME, FL_GRPC_KEEPALIVE_TIMEOUT, FL_CERT_EXTRA_SAN)
affects: [08-monitoring-observability, 09-edge-auto-scaling]

# Tech tracking
tech-stack:
  added: [wireguard]
  patterns: [per-zone-oneflow-services, hub-and-spoke-vpn, static-ca-distribution]

key-files:
  created:
    - spec/12-multi-site-federation.md
  modified: []

key-decisions:
  - "WireGuard recommended over IPsec for cross-zone VPN (simpler, in-kernel, Ubuntu 24.04 native)"
  - "FL_TLS_ENABLED defaults to YES in multi-site templates (cross-zone traffic must be encrypted)"
  - "60-second gRPC keepalive interval (below most aggressive firewall idle timeouts)"
  - "FL_CERT_EXTRA_SAN variable for multi-homed SuperLink SAN entries"
  - "Hub-and-spoke VPN topology (all training sites connect to coordinator zone)"
  - "FL_SUPERLINK_ADDRESS mandatory (M|text) in training site template (no OneGate cross-zone)"

patterns-established:
  - "Per-zone OneFlow services: each zone has independent service; cross-zone coordination is operator workflow"
  - "Static CA distribution: FL_SSL_CA_CERTFILE as the cross-zone TLS trust mechanism"
  - "Keepalive coordination: client keepalive_time >= server min_recv_ping_interval"

# Metrics
duration: 6min
completed: 2026-02-09
---

# Phase 7 Plan 1: Multi-Site Federation Specification Summary

**Complete 952-line multi-site federation spec covering 3-zone topology, WireGuard/direct-IP networking, gRPC keepalive (60s/20s), cross-zone TLS trust distribution, and end-to-end deployment walkthrough**

## Performance

- **Duration:** 6 min
- **Started:** 2026-02-09T10:10:25Z
- **Completed:** 2026-02-09T10:16:23Z
- **Tasks:** 2
- **Files created:** 1

## Accomplishments
- Created complete spec/12-multi-site-federation.md (952 lines, 12 sections) satisfying ORCH-02
- Defined 3-zone reference deployment topology with per-zone OneFlow service template JSON for both coordinator and training site variants
- Specified two cross-zone networking options (WireGuard VPN and direct public IP) with selection criteria decision matrix
- Defined gRPC keepalive configuration (60s time, 20s timeout) with client/server coordination rules
- Documented TLS certificate trust distribution workflows for both self-signed CA and enterprise PKI paths
- Created end-to-end 3-zone deployment walkthrough with step-by-step commands and verification procedures
- Introduced three new CONTEXT variables: FL_GRPC_KEEPALIVE_TIME, FL_GRPC_KEEPALIVE_TIMEOUT, FL_CERT_EXTRA_SAN

## Task Commits

Each task was committed atomically:

1. **Task 1: Sections 1-6 (Topology, Templates, Networking)** - `43895a0` (feat)
2. **Task 2: Sections 7-12 (Keepalive, TLS Trust, Walkthrough, Anti-Patterns)** - `cdd0e48` (feat)

## Files Created/Modified
- `spec/12-multi-site-federation.md` - Complete multi-site federation specification (952 lines, 12 sections, ORCH-02)

## Decisions Made
- WireGuard recommended as default for production (defense-in-depth, simpler TLS SAN handling)
- FL_TLS_ENABLED defaults to YES in both coordinator and training site templates (cross-zone must be encrypted)
- 60-second gRPC keepalive chosen (below 60s aggressive firewall threshold, 2x safety margin over server's 30s min)
- FL_CERT_EXTRA_SAN introduced to avoid forcing operator-provided certs for WireGuard deployments
- Hub-and-spoke VPN topology recommended (all sites connect to coordinator; no inter-site peering needed)
- FL_SUPERLINK_ADDRESS changed from optional to mandatory in training site template

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- spec/12-multi-site-federation.md is complete and ready for Phase 7 Plan 2 (if applicable)
- spec/03-contextualization-reference.md will need updating with the 3 new Phase 7 variables (FL_GRPC_KEEPALIVE_TIME, FL_GRPC_KEEPALIVE_TIMEOUT, FL_CERT_EXTRA_SAN)
- spec/00-overview.md will need updating to include Phase 7 in the spec sections table
- The gRPC keepalive implementation depends on Flower's configuration surface for channel options (noted as LOW confidence in research)

## Self-Check: PASSED

---
*Phase: 07-multi-site-federation*
*Completed: 2026-02-09*
