---
phase: 08-monitoring-and-observability
plan: 01
subsystem: monitoring
tags: [prometheus, grafana, dcgm, json-logging, alerting, observability]
depends_on:
  requires: [phase-01, phase-05, phase-06]
  provides: [monitoring-spec, obs-01-logging, obs-02-metrics]
  affects: [phase-08-plan-02, phase-09]
tech-stack:
  added: [prometheus_client, dcgm-exporter, grafana-dashboards, alertmanager-rules]
  patterns: [two-tier-monitoring, exporter-pull-model, structured-json-logging, sidecar-container]
key-files:
  created:
    - spec/13-monitoring-observability.md
  modified: []
decisions:
  - "Two-tier monitoring: OBS-01 (JSON logging, zero infrastructure) standalone; OBS-02 (Prometheus/Grafana) builds on it"
  - "Appliances run EXPORTERS only; monitoring infrastructure (Prometheus, Grafana, Alertmanager) is operator-managed"
  - "prometheus_client embedded in ServerApp FAB, not in base Flower Docker image"
  - "DCGM Exporter pulled at boot time (not pre-baked in QCOW2) to keep base image size stable"
  - "Port 9101 for FL metrics exporter; 9400 for DCGM (avoids Flower port range 9091-9093)"
  - "No 'round' label on Prometheus metrics -- prevents unbounded cardinality"
  - "FL_LOG_FORMAT as service-level variable; FL_METRICS_* as SuperLink role-level; FL_DCGM_ENABLED as SuperNode role-level"
  - "DCGM not started is degraded monitoring, not fatal -- training continues without GPU metrics"
metrics:
  duration: 5 min
  completed: 2026-02-09
---

# Phase 8 Plan 1: Monitoring and Observability Specification Summary

**One-liner:** Two-tier monitoring spec with structured JSON logging (12 FL events), Prometheus metrics (11 FL + 8 DCGM GPU), 3 Grafana dashboards, 8 alerting rules, and 4 new CONTEXT variables.

## What Was Done

Created `spec/13-monitoring-observability.md` -- a complete, self-contained specification covering both OBS-01 (structured logging) and OBS-02 (Prometheus/Grafana monitoring stack) requirements.

### Sections Written

1. **Purpose and Scope** -- Two-tier architecture, cross-references, scope boundaries
2. **Monitoring Architecture Diagram** -- ASCII diagram with port allocation table (7 ports documented)
3. **Tier 1: Structured JSON Logging (OBS-01)** -- JSON format spec, 12 FL event types, FlowerJSONFormatter implementation, log_fl_event helper, Docker log capture
4. **New Contextualization Variables** -- 4 variables (FL_LOG_FORMAT, FL_METRICS_ENABLED, FL_METRICS_PORT, FL_DCGM_ENABLED) with interaction matrix and USER_INPUT definitions
5. **Tier 2: Flower Training Metrics Exporter** -- 11 Prometheus metrics, label cardinality rules, reference implementation, integration points
6. **Tier 2: DCGM Exporter for GPU Metrics** -- Sidecar container spec, systemd unit, 8 DCGM metrics, lifecycle rules, pull strategy
7. **Tier 2: Prometheus Scrape Configuration** -- Reference scrape config (fl_training + dcgm_gpu jobs), service discovery notes, network requirements
8. **Grafana Dashboard Definitions** -- 3 dashboards (FL Training Overview: 6 panels, GPU Health: 6 panels, Client Health: 4 panels) with PromQL queries
9. **Alerting Rules** -- 4 FL training alerts + 4 GPU health alerts with complete YAML, Alertmanager integration reference
10. **Boot Sequence Integration** -- SuperLink changes (JSON formatter, metrics server), SuperNode changes (DCGM sidecar at Step 15), validation rules
11. **Failure Modes and Recovery** -- 7 failure scenarios with symptoms, impact, and recovery steps
12. **Anti-Patterns** -- 6 anti-patterns with explanations and correct alternatives
13. **Contextualization Variables Summary** -- Complete USER_INPUT definitions, variable count update (42 -> 46)

## Task Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1-2 | Complete monitoring and observability specification | f6a4687 | spec/13-monitoring-observability.md |

## Decisions Made

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Two-tier monitoring (OBS-01 standalone, OBS-02 builds on it) | Zero-infrastructure baseline (JSON logs) for all deployments; full metrics stack for production |
| 2 | Exporters on appliance VMs; Prometheus/Grafana operator-managed | Immutable appliance design; avoids resource contention with training |
| 3 | prometheus_client in ServerApp FAB, not Flower image | Decouples monitoring from Flower version; no base image modification |
| 4 | DCGM image pulled at boot, not pre-baked | Keeps QCOW2 size stable; DCGM is optional monitoring addon |
| 5 | Port 9101 for FL metrics | Avoids Flower ports 9091-9093 and Prometheus 9090 |
| 6 | No "round" label on metrics | Prevents unbounded Prometheus cardinality from long training runs |
| 7 | FL_LOG_FORMAT at service level | Consistent logging format across both appliances in a deployment |
| 8 | DCGM failure is WARNING, not FATAL | Consistent with Phase 6 DR-05 (degraded > missing) |

## Deviations from Plan

None -- plan executed exactly as written. Both tasks were completed as a single file creation since all 13 sections form one cohesive specification document.

## Verification Results

All verification criteria passed:

- spec/13-monitoring-observability.md exists with 1024 lines (> 500 minimum)
- SC1 (structured logging): FL Event Taxonomy with 12 event types present
- SC2 (Prometheus metrics): fl_round_current, DCGM_FI_DEV_GPU_UTIL present
- SC3 (Grafana dashboards): FL Training Overview, GPU Health, Client Health dashboards defined
- SC4 (alerting rules): FLTrainingStalled, GPUMemoryExhaustion, GPUTemperatureCritical present
- New CONTEXT variables: FL_LOG_FORMAT, FL_METRICS_ENABLED, FL_METRICS_PORT, FL_DCGM_ENABLED defined
- Port allocation table with 9101 and 9400 present
- Requirements OBS-01 and OBS-02 in header
- Two-tier structure clear

## Next Phase Readiness

**For 08-02 (spec integration):** The monitoring spec is complete and ready for integration into the contextualization reference and overview. Key integration points:
- 4 new variables to add to `spec/03-contextualization-reference.md`
- Phase 8 section to add to `spec/00-overview.md`
- Boot sequence updates to document in `spec/01-superlink-appliance.md` and `spec/02-supernode-appliance.md`

**Blockers:** None.

## Self-Check: PASSED
