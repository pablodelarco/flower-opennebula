# Flower-OpenNebula Integration Spec

## What This Is

A comprehensive technical specification for integrating the Flower federated learning framework into the OpenNebula cloud platform and its marketplace. This spec serves as the shared reference document for both Flower Labs and OpenNebula engineering to guide the integration work under the Fact8ra initiative — Europe's first federated AI-as-a-Service platform.

## Core Value

Enable privacy-preserving federated learning on distributed OpenNebula infrastructure through marketplace appliances that any tenant can deploy with minimal configuration.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Architecture design covering single-site, multi-site, and edge deployment topologies
- [ ] Appliance design specification with packaging format analysis and recommendation (Docker vs VM/QCOW2 vs Helm)
- [ ] Networking and security model for Flower server-client communication across multi-tenant OpenNebula environments
- [ ] OpenNebula contextualization parameter mapping for Flower configuration (server address, rounds, aggregation strategy, ML framework, dataset)
- [ ] OneFlow service template design for orchestrated Flower cluster deployment
- [ ] GPU passthrough specification for accelerated training on client nodes
- [ ] Pilot/PoC plan with a concrete federated learning scenario, success criteria, and deployment steps
- [ ] Deployment workflow documentation: step-by-step from marketplace to running FL job
- [ ] Technical investigation task list and questions for Flower Labs follow-up call
- [ ] Integration roadmap with phased milestones (MVP → production-ready → advanced features)
- [ ] Risk assessment with mitigation strategies
- [ ] Monitoring and observability recommendations for FL training runs

### Out of Scope

- Building the actual appliances, Dockerfiles, or Helm charts — this project produces the spec, not the implementation
- Flower framework modifications or custom patches — we integrate with upstream Flower as-is
- OpenNebula core platform changes — the integration works within existing marketplace/OneFlow/contextualization capabilities
- Production hardening (HA, disaster recovery, SLA) — deferred to post-MVP phases in the roadmap
- Non-EU deployment considerations — Fact8ra is EU-sovereign by design

## Context

### The Fact8ra Initiative
Fact8ra is OpenNebula's sovereign AI platform under the €3B IPCEI-CIS project. It federates GPU resources across 8 EU countries. Current capabilities cover AI inference (LLM deployment with Mistral, EuroLLM, Hugging Face). Future phases add fine-tuning and training — this Flower integration is part of that expansion.

### Flower Framework
Flower is the leading open-source federated learning framework with a hub-and-spoke architecture. Central server coordinates training rounds; distributed clients train locally on their own data and share only model weights/gradients. Framework-agnostic (PyTorch, TensorFlow, Hugging Face, JAX, scikit-learn). Docker images available for both server and client.

### OpenNebula Marketplace
Appliances are pre-packaged VM images or container definitions users deploy from the marketplace. Existing pattern: LitOps uses client/server components packaged as appliances. Supports QCOW2 images, Docker references in service templates, Helm charts for Kubernetes deployments. OneFlow orchestrates multi-VM service deployments.

### Target Users
- Telco companies deploying edge AI across distributed 5G infrastructure
- AI Factories and HPC centers in the Fact8ra federation
- Enterprises with distributed sensitive data (healthcare, finance, industrial IoT)

### Flower Labs Relationship
€15K consulting budget from IPCEI-CIS for Flower Labs to assist with the integration. This spec guides their contribution and aligns both teams on architecture and deliverables.

### Author's Background
Cloud-Edge Innovation Engineer at OpenNebula Systems. Experience with Docker, Kubernetes, Helm charts, and ARM64 appliance creation for the OpenNebula marketplace.

## Constraints

- **Budget**: €15K consulting budget for Flower Labs assistance — spec must be actionable within this envelope
- **Timeline**: Demo-ready target for Flower AI Summit (April 15-16, London) or OpenNebula OneNext event (April, Brussels)
- **Platform**: Must work within existing OpenNebula marketplace, OneFlow, and contextualization capabilities — no core platform changes
- **Sovereignty**: EU-sovereign stack (OpenNebula, openSUSE, MariaDB, NVIDIA GPUs) — no dependencies on non-EU cloud services
- **Multi-tenancy**: Appliances must support proper tenant isolation on shared infrastructure
- **Upstream Flower**: Integrate with upstream Flower Docker images and APIs — no custom forks

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Technical spec only, not implementation | Spec guides both Flower Labs and OpenNebula eng teams | — Pending |
| Deployment format (Docker vs VM vs Helm) | Genuinely open — spec should analyze trade-offs and recommend | — Pending |
| Shared reference document for both teams | Flower Labs and OpenNebula eng need aligned architecture | — Pending |
| Telco edge AI as priority use case | Highest market demand from both companies | — Pending |

---
*Last updated: 2026-02-05 after initialization*
