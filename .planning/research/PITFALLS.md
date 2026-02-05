# Domain Pitfalls: Flower FL + OpenNebula Cloud Integration

**Domain:** Federated learning marketplace appliances for distributed cloud infrastructure
**Researched:** 2026-02-05
**Overall confidence:** MEDIUM (verified against official Flower docs, OpenNebula docs, and community sources)

---

## Critical Pitfalls

Mistakes that cause rewrites, demo failures, or project-level blockers. Address these in the earliest possible phase.

---

### Pitfall 1: Flower Version Drift Between Server and Client Appliances

**What goes wrong:** The SuperLink appliance runs Flower v1.25 while client appliances downloaded weeks earlier run v1.23. Flower has had significant breaking changes between versions -- the v1.24 release dropped Python 3.9, bumped protobuf to 5.x (incompatible with TensorFlow < 2.18), removed CSV-based SuperNode authentication, and renamed authentication YAML keys. The v1.25 release removed bundled templates from `flwr new`. Earlier versions migrated the entire internal message system from TaskIns/TaskRes to Message-based APIs. A version mismatch between SuperLink and SuperNode will cause silent failures, protocol errors, or authentication rejections.

**Why it happens:** Marketplace appliances are immutable images. Once a tenant downloads a server appliance in January and a client appliance in March, there is no mechanism forcing version alignment. Flower's release cadence (roughly monthly) means even a small gap can cross a breaking-change boundary.

**Consequences:**
- gRPC protocol mismatches cause connection failures with cryptic error messages
- Authentication key format changes cause SuperNodes to be rejected
- protobuf version conflicts cause serialization/deserialization failures during model parameter exchange
- Tenants blame "the platform" rather than version skew

**Prevention:**
- Pin Flower version explicitly in every appliance image and encode it in appliance metadata
- Implement a version handshake check in the contextualization scripts: SuperNode startup should query SuperLink version (via a health endpoint or metadata) and refuse to start with a clear error if versions diverge
- Ship server and client appliances as a matched pair with the same version tag (e.g., `flower-server-1.25.0`, `flower-client-1.25.0`)
- Use OneFlow service templates to deploy server+clients atomically, preventing mixed-version federations
- Document the Flower upgrade path in appliance release notes

**Detection:**
- SuperNodes fail to connect with gRPC status code UNIMPLEMENTED or INTERNAL
- Authentication failures despite correct keys
- Serialization errors in model parameter exchange
- Check `pip show flwr` on both sides

**Confidence:** HIGH -- verified against Flower changelog (https://flower.ai/docs/framework/ref-changelog.html) and upgrade guides (https://flower.ai/docs/framework/how-to-upgrade-to-flower-1.13.html)

**Phase:** Must be addressed in Phase 1 (appliance packaging). This is a design-time decision, not a runtime fix.

---

### Pitfall 2: TLS Certificate Distribution and Lifecycle in Marketplace Appliances

**What goes wrong:** TLS is mandatory for any multi-machine Flower deployment (SuperNode authentication requires it, and official docs strongly recommend it for all production use). But marketplace appliances are generic images -- they cannot ship with pre-baked certificates because every tenant's federation is unique. Teams either skip TLS ("we'll add it later"), hard-code self-signed certs into images (shared across all tenants), or leave certificate generation as a manual step that most users never complete.

**Why it happens:** Flower's TLS model requires three files distributed correctly:
- CA certificate (`ca.crt`) -- shared by all components
- Server certificate + key (`server.pem`, `server.key`) -- on SuperLink only
- The SuperNode only needs the CA cert for verification

This is straightforward in a tutorial but extremely difficult to automate in a marketplace appliance where the deployer may not understand PKI. The official Flower docs explicitly warn that their certificate generation scripts are "suitable for prototyping" and "should not be used as a reference for production environments."

Additionally, Flower Docker containers run as non-root user `app` (UID 49999), and mounted certificate files must have permissions set for this UID. This is a commonly reported issue.

**Consequences:**
- Federations deployed with `--insecure` flag, defeating the privacy value proposition of FL
- Certificate permission errors cause silent startup failures in containers
- Expired certificates break running federations with no clear error path
- Shared self-signed certs across tenants create a cross-tenant security vulnerability

**Prevention:**
- Build automated certificate generation into the contextualization/cloud-init phase: when the SuperLink appliance boots for the first time, generate a CA + server cert, and expose the CA cert via OneGate so client appliances can retrieve it
- Use OpenNebula's OneGate API for certificate distribution: SuperLink VM pushes CA cert to OneGate, SuperNode VMs pull it during contextualization
- Enforce TLS-only in appliance startup scripts -- never ship an `--insecure` mode in production appliances
- Set correct file ownership (UID 49999) in contextualization scripts before starting Flower containers
- Implement certificate rotation or at minimum set long expiry (1 year) with monitoring alerts
- Consider using an ACME-like approach with an internal CA for automated renewal

**Detection:**
- grep logs for "insecure" or "SSL" errors
- Certificate permission errors appear as "Permission denied" on `/app/certificates/` paths
- Connection refused errors on port 9092 when TLS handshake fails

**Confidence:** HIGH -- verified against official Flower TLS docs (https://flower.ai/docs/framework/how-to-enable-tls-connections.html) and Docker TLS guide (https://flower.ai/docs/framework/docker/enable-tls.html)

**Phase:** Must be addressed in Phase 1 (appliance packaging) with the certificate automation design, refined in Phase 2 (multi-site) when cross-site certificate trust becomes relevant.

---

### Pitfall 3: GPU Passthrough Configuration Fragility in OpenNebula

**What goes wrong:** GPU passthrough for ML training workloads requires a precise stack of IOMMU, VFIO driver binding, UEFI firmware, q35 machine type, CPU pinning to the correct NUMA node, and correct PCI address assignment. Any misconfiguration in this chain causes the GPU to either not appear in the VM, appear but fail to initialize, or work with severely degraded performance. OpenNebula has known issues: GPU passthrough broke when vGPU support was added, NVIDIA GPUs sometimes do not appear in PCI device lists, and multi-GPU passthrough can cause extremely slow GPU initialization.

**Why it happens:** GPU passthrough is a host-level configuration that varies by hardware vendor, GPU model, motherboard BIOS, and kernel version. A marketplace appliance can configure the guest OS correctly, but it cannot configure the host. The OpenNebula admin must separately:
1. Enable IOMMU in BIOS and kernel parameters
2. Bind the GPU to vfio-pci driver (and this unbinding from nouveau/nvidia must survive reboots)
3. Set correct udev rules for VFIO device permissions
4. Configure PCI monitoring filters in OpenNebula (`/var/lib/one/remotes/etc/im/kvm-probes.d/pci.conf`)
5. Wait up to 10 minutes for GPU detection or force-update the host

Additionally, NVIDIA driver version compatibility is a three-layer problem: kernel-mode driver, user-mode driver, and NVIDIA runtime must all be compatible with each other AND with the CUDA toolkit version installed in the guest VM.

**Consequences:**
- GPU not visible inside VM -- training falls back to CPU silently or fails entirely
- GPU visible but slow -- missing NUMA affinity or Resizable BAR support
- Driver mismatch between host vfio-pci setup and guest NVIDIA driver causes kernel panics
- Demo failure at the worst possible time because GPU works on dev host but not production host

**Prevention:**
- Create a separate "GPU host preparation" guide and validation script that checks all prerequisites before any FL appliance is deployed
- Ship a `gpu-check` appliance or script that validates: IOMMU enabled, VFIO bound, PCI device visible, driver version compatibility
- In the appliance VM template, enforce UEFI firmware, q35 machine type, host-passthrough CPU model, and NUMA-aware CPU pinning as documented requirements
- Pin CUDA toolkit + driver versions in the client appliance and document the minimum host driver version required
- For the April demo, identify the exact hardware and validate GPU passthrough works end-to-end BEFORE building the full FL stack on top of it
- Consider offering a CPU-only deployment path as fallback for the demo

**Detection:**
- `nvidia-smi` returns "No devices found" inside the VM
- `dmesg | grep -i iommu` shows no IOMMU groups on the host
- `lspci` inside VM does not show NVIDIA device
- Training runs 100x slower than expected (fell back to CPU)

**Confidence:** HIGH -- verified against OpenNebula 7.0 GPU passthrough docs (https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/nvidia_gpu_passthrough/) and community forum reports (https://forum.opennebula.io/t/gpu-passthrough-no-longer-works-since-vgpu-support-was-added/10855)

**Phase:** Must be validated in Phase 1 (proof of concept). GPU passthrough is a hard dependency -- if it does not work on the target hardware, the entire project scope changes.

---

### Pitfall 4: SuperLink Networking Assumptions in Multi-Site Deployments

**What goes wrong:** Flower's architecture requires SuperNodes to make outbound gRPC connections to the SuperLink on ports 9092 (Fleet API) and optionally 9091 (ServerAppIo). This is by design -- SuperNodes only initiate connections, never accept them, which is NAT-friendly. However, the SuperLink itself must be reachable from ALL client sites. In a multi-site OpenNebula deployment, the SuperLink sits behind one site's network, and clients at other sites must traverse firewalls, NATs, and potentially the public internet to reach it.

**Why it happens:** In single-site deployments, everything is on the same VNET and "just works." Teams build and test single-site, then discover multi-site networking is a fundamentally different problem. The SuperLink needs:
- A stable, routable IP or hostname (not a private 10.x.x.x address)
- Ports 9091, 9092, 9093 accessible from all sites
- gRPC connections are long-lived HTTP/2 streams that get killed by load balancer idle timeouts (AWS ALB: 60s, GCP: 600s, Azure: 4min) and stateful firewalls

Additionally, Flower recently changed all gRPC metadata keys from underscores to hyphens specifically because load balancers and reverse proxies silently drop headers with underscores.

**Consequences:**
- SuperNodes connect from the local site but fail from remote sites
- Connections succeed initially but drop after idle timeout, causing training rounds to fail mid-aggregation
- Stateful firewalls close "idle" gRPC connections between training rounds
- Load balancers or reverse proxies strip critical gRPC metadata headers

**Prevention:**
- Design the multi-site networking architecture BEFORE building appliances -- this determines whether you need VPN tunnels, public IPs, or a relay architecture
- Configure gRPC keepalive on SuperNodes (recommendation: keepalive interval under the shortest load balancer timeout in the path, minimum 60 seconds)
- If deploying behind a reverse proxy, ensure it supports HTTP/2 end-to-end and does not strip gRPC metadata headers
- Use the SuperLink's FQDN (not IP) in SuperNode configuration to support DNS-based failover
- For cross-site deployments, consider a VPN mesh (WireGuard/Tailscale) between OpenNebula sites as the simplest path to flat networking
- Test with actual multi-site latency and firewall rules, not just "two VMs on different subnets of the same host"

**Detection:**
- SuperNodes connect from local site, timeout from remote site
- Training starts but fails after long idle periods between rounds
- gRPC UNAVAILABLE errors in SuperNode logs
- Flower logs show "metadata" or "header" related warnings

**Confidence:** HIGH -- verified against Flower network communication docs (https://flower.ai/docs/framework/ref-flower-network-communication.html) and gRPC keepalive best practices (https://grpc.io/docs/guides/keepalive/)

**Phase:** Phase 1 (single-site) should work without this concern. Phase 2 (multi-site) is where this becomes the primary technical challenge. Design the networking approach during Phase 1 even though it is not implemented until Phase 2.

---

### Pitfall 5: OneGate Service Discovery Fragility for Dynamic FL Topologies

**What goes wrong:** OpenNebula's OneGate API is the only built-in mechanism for VMs within a OneFlow service to discover each other. The FL server appliance needs to advertise its IP/port, and client appliances need to discover it. But OneGate has limitations: it requires `TOKEN = "YES"` in contextualization, data is exchanged via PUT/GET on VM user templates (key-value strings, not structured data), and there is no pub/sub or notification mechanism -- clients must poll.

**Why it happens:** OneGate was designed for simple service orchestration (web app + database), not for dynamic ML topologies where:
- The server must be fully ready (TLS configured, listening) before clients connect
- Clients may scale up/down during a training session
- The server IP may change if the VM is migrated

Teams either over-engineer a custom service discovery layer (complexity) or under-engineer with hard-coded IPs in contextualization variables (brittleness).

**Consequences:**
- Race condition: client VMs boot and try to connect before the server VM has finished TLS setup
- Hard-coded IPs break when VMs are restarted or migrated
- No mechanism to signal "server is ready" to clients -- clients fail on first connection attempt and may not retry correctly
- Scaling clients mid-session requires manual reconfiguration

**Prevention:**
- Use OneFlow's role ordering: define the server role first, clients second, with a dependency so clients only start after the server role is RUNNING
- Implement a health-check loop in client contextualization: poll OneGate for the server's advertised endpoint until it responds, with exponential backoff and a clear timeout/error message
- Have the server VM push its endpoint (IP:port) AND readiness status to OneGate after TLS is configured and Flower SuperLink is confirmed listening
- Keep the OneGate approach simple (just endpoint discovery) -- do not try to build a full configuration management system on top of it
- For advanced topologies, consider a lightweight config server (etcd or even a file on a shared NFS mount) as an alternative to OneGate

**Detection:**
- Client VMs in RUNNING state but SuperNode logs show "connection refused" to the server
- OneGate API returns empty or stale endpoint data
- `onegate vm show` from inside a client VM returns no server IP

**Confidence:** MEDIUM -- OneGate behavior verified against OpenNebula 6.8 and 7.0 docs (https://docs.opennebula.io/6.8/integration_and_development/system_interfaces/onegate_api.html). Specific FL-topology usage is extrapolated from the API capabilities.

**Phase:** Phase 1 (single-site OneFlow deployment). This is foundational -- if service discovery does not work cleanly, every subsequent phase inherits the problem.

---

## Moderate Pitfalls

Mistakes that cause delays, rework, or degraded user experience. Address in the phase where they become relevant.

---

### Pitfall 6: CUDA Memory Exhaustion with Multiple FL Clients on Shared GPU

**What goes wrong:** When multiple Flower SuperNodes share a GPU (via vGPU or even sequential use), CUDA allocates a fixed memory pool per process at initialization that is never freed until process exit. If two SuperNodes each request the default GPU memory allocation, the second one gets an OOM error or both get degraded performance. Flower treats each client as an independent process, so memory requirements scale linearly with the number of concurrent clients per GPU.

**Why it happens:** CUDA's default memory allocation strategy pre-allocates a large fraction of GPU VRAM. In federated learning, models are loaded per-client, and if multiple clients are scheduled on the same node (common in simulation or multi-tenant scenarios), they compete for GPU memory without coordination.

**Prevention:**
- Set `CUDA_VISIBLE_DEVICES` per SuperNode container to isolate GPU assignment
- Use `torch.cuda.set_per_process_memory_fraction()` or TensorFlow's `gpu_options.per_process_gpu_memory_growth = True` in client code
- For multi-tenant scenarios, use NVIDIA MIG (on supported GPUs like H100) to create hardware-isolated GPU partitions
- Document GPU VRAM requirements per model in the appliance metadata so tenants can right-size their allocations
- Consider offering a `data_sampling_percentage` parameter in appliance configuration for memory-constrained environments

**Detection:**
- CUDA OOM errors in training logs
- `nvidia-smi` shows one process consuming all VRAM
- Training starts but crashes after first forward pass

**Confidence:** HIGH -- verified via Flower GitHub issues (https://github.com/adap/flower/issues/3238) and Flower community forums (https://discuss.flower.ai/t/how-to-prevent-oom-error-while-training/286)

**Phase:** Phase 1 if GPU training is part of the initial proof of concept. Phase 3 (multi-tenant) for shared GPU scenarios.

---

### Pitfall 7: Appliance Image Bloat and Boot Time

**What goes wrong:** An FL client appliance needs: base OS, Python runtime, Flower framework, ML framework (PyTorch/TensorFlow), CUDA toolkit, cuDNN, model weights, and dataset utilities. A naive approach produces 15-30 GB images that take 10+ minutes to download from the marketplace and 5+ minutes to boot. This makes the "spin up a federation in minutes" value proposition impossible.

**Why it happens:** ML dependencies are enormous. PyTorch with CUDA support alone is ~2.5 GB. TensorFlow is similar. The CUDA toolkit adds another ~4 GB. Teams include every possible dependency "just in case" rather than building minimal, layered images.

**Prevention:**
- Build a minimal base appliance with only Flower + one ML framework (recommend PyTorch as Flower's primary framework)
- Use NVIDIA container toolkit (nvidia-docker) instead of installing CUDA in the base image -- mount the host GPU driver and CUDA at runtime
- Separate the "Flower infrastructure" layer (SuperNode + gRPC + TLS) from the "ML application" layer (model + data) -- the infrastructure layer is the marketplace appliance, the ML layer is user-provided
- Offer framework-specific appliance variants (flower-client-pytorch, flower-client-tensorflow) rather than one bloated universal image
- Use QCOW2 thin provisioning for the marketplace image format
- Pre-pull common model architectures but do NOT embed training data

**Detection:**
- Marketplace download takes more than 5 minutes on reasonable bandwidth
- VM boot to "ready for training" takes more than 3 minutes
- Disk usage exceeds 20 GB for a client appliance

**Confidence:** MEDIUM -- based on known ML dependency sizes and marketplace appliance mechanics. Specific boot times are hardware-dependent.

**Phase:** Phase 1 (appliance packaging). Image size decisions made here propagate through every phase.

---

### Pitfall 8: Non-IID Data Distribution Causing Training Divergence

**What goes wrong:** In production federated learning, each client has different data distributions (label skew, quantity skew, feature skew). The default FedAvg aggregation strategy assumes roughly IID data across clients. With highly non-IID data, model convergence slows dramatically or the global model diverges entirely, and tenants conclude "FL doesn't work."

**Why it happens:** This is a fundamental FL challenge, not a Flower bug. But it becomes a platform pitfall when the marketplace appliance defaults to FedAvg without guidance on when it will fail. Non-ML-expert users deploying from a marketplace will not understand why their model accuracy is degrading round over round.

**Prevention:**
- Default to FedProx instead of FedAvg in the appliance -- it adds a proximal term that prevents client drift with minimal overhead and has the same convergence speed as FedAvg on IID data
- Include convergence monitoring in the default deployment (Flower supports Prometheus metrics + Grafana dashboards in Docker Compose)
- Provide clear documentation: "If training accuracy decreases over rounds, your data may be non-IID. Try these strategies: [FedProx, FedNova, weighted aggregation]"
- Add a data heterogeneity diagnostic tool that measures label distribution across clients before training starts
- Set reasonable defaults for local epochs (2-5) and learning rate schedules

**Detection:**
- Global model accuracy decreases over rounds instead of improving
- High variance in per-client loss values
- Model weights oscillate between rounds

**Confidence:** HIGH -- this is well-documented in FL literature. FedProx recommendation verified against multiple academic sources and Flower's strategy implementations.

**Phase:** Phase 1 for choosing the default strategy. Phase 3 (production readiness) for monitoring and diagnostics tooling.

---

### Pitfall 9: Contextualization Script Ordering and Failure Handling

**What goes wrong:** OpenNebula contextualization (cloud-init) runs scripts at boot time to configure the VM. For FL appliances, this must: set up networking, retrieve configuration from OneGate, generate or retrieve TLS certificates, configure Flower, and start the SuperLink or SuperNode service. If any step fails silently or runs out of order, the appliance boots into a broken state with no clear error message.

**Why it happens:** cloud-init script ordering depends on the cloud-init phase (per-instance vs. per-boot) and script naming conventions. OpenNebula's contextualization runs scripts in lexical order. Teams put everything in one monolithic script without error handling, or split into multiple scripts without ensuring dependencies.

**Consequences:**
- Flower starts before TLS certs are generated -- falls back to insecure mode or crashes
- SuperNode starts before OneGate is reachable -- fails to discover server endpoint
- Network is not ready when contextualization scripts run -- all external fetches fail
- No log output when scripts fail -- VM appears healthy but FL is not running

**Prevention:**
- Number scripts explicitly: `01-network-check.sh`, `02-onegate-discovery.sh`, `03-tls-setup.sh`, `04-flower-start.sh`
- Each script should validate its preconditions and fail loudly with a clear message written to both syslog and a well-known file (`/var/log/flower-setup.log`)
- Use systemd units with `After=` dependencies instead of raw cloud-init scripts for Flower services
- Implement a health endpoint that reports readiness status (not just "VM is running" but "Flower SuperLink is accepting connections on port 9092 with TLS")
- Test contextualization in a clean environment every time the appliance image changes

**Detection:**
- VM shows as RUNNING in OpenNebula but no Flower process is listening
- `/var/log/cloud-init-output.log` shows errors
- `systemctl status flower-superlink` shows failed state

**Confidence:** MEDIUM -- OpenNebula contextualization behavior verified against docs. Specific failure modes are based on general cloud-init operational experience.

**Phase:** Phase 1 (appliance packaging). This is the single most impactful quality-of-life decision for users.

---

### Pitfall 10: Multi-Tenant Isolation -- Flower's Multi-Run vs. OpenNebula's Multi-Tenant Model Mismatch

**What goes wrong:** Flower supports multi-tenancy through "Multi-Run" -- multiple independent Flower apps share the same SuperLink and SuperNodes, with each run operating on a different subset of clients. OpenNebula's multi-tenancy is at the VM/resource level -- different tenants get different VMs with resource quotas. These are fundamentally different isolation models. Using Flower's multi-run on a shared SuperLink means tenant A's training metadata (run IDs, client participation, timing) is visible to the SuperLink operator. Using separate SuperLink instances per tenant means each tenant needs their own infrastructure, defeating the "shared platform" efficiency.

**Why it happens:** Flower's multi-tenant model assumes a trusted operator running the SuperLink with multiple projects. OpenNebula's model assumes untrusted tenants sharing infrastructure. There is no built-in mechanism in Flower to enforce that tenant A's SuperNodes cannot be enlisted into tenant B's training run by a compromised or misconfigured SuperLink.

**Consequences:**
- If using shared SuperLink: no data plane isolation between tenants, potential for model poisoning across tenants, privacy violation of the core FL promise
- If using per-tenant SuperLink: resource waste (each tenant needs a dedicated SuperLink VM), management overhead, networking complexity multiplied per tenant
- EU sovereignty and GDPR concerns if tenant data boundaries are not enforced at the infrastructure level

**Prevention:**
- Recommend per-tenant SuperLink instances for the initial release -- this is simpler, more secure, and aligns with OpenNebula's VM-level isolation model
- Each tenant deploys their own OneFlow service (SuperLink + N SuperNodes) as an isolated federation
- Use OpenNebula VNETs to network-isolate tenant federations from each other
- Document the Flower multi-run capability as a power-user feature for single-tenant scenarios (e.g., one organization running multiple experiments), not as the multi-tenant solution
- Revisit shared-SuperLink multi-tenancy only after Flower adds stronger run-level isolation (consult with Flower Labs during the consulting engagement)

**Detection:**
- Tenants can see other tenants' run metadata via the Flower CLI
- SuperNodes from one tenant appear in another tenant's federation
- Network scanning from one tenant's VNET reaches another tenant's SuperLink

**Confidence:** HIGH for Flower's multi-run architecture (verified at https://flower.ai/docs/framework/explanation-flower-architecture.html). MEDIUM for the isolation implications (extrapolated from the architecture -- specific enforcement mechanisms not documented).

**Phase:** Phase 3 (multi-tenant). But the decision between shared-SuperLink vs. per-tenant-SuperLink must be made in Phase 1 because it determines the appliance architecture.

---

## Minor Pitfalls

Mistakes that cause annoyance, minor rework, or confusion. Address when encountered.

---

### Pitfall 11: OneFlow Service Template Name Length Limits

**What goes wrong:** If the combined name of the VM template + Service template exceeds 128 characters, the VM template name gets silently cropped. With descriptive names like `flower-federated-learning-server-gpu-pytorch-v1.25.0`, this limit is easily hit.

**Prevention:** Keep all template and service names under 60 characters. Use short, systematic naming: `fl-server-1.25`, `fl-client-gpu-1.25`.

**Confidence:** HIGH -- documented in OpenNebula OneFlow docs.

**Phase:** Phase 1.

---

### Pitfall 12: protobuf 5.x Incompatibility with Older TensorFlow

**What goes wrong:** Flower v1.24+ requires protobuf >= 5.29.0, which is incompatible with TensorFlow versions earlier than 2.18. If a tenant's custom FL code uses an older TensorFlow version, Flower will either fail to import or produce serialization errors.

**Prevention:**
- Pin TensorFlow >= 2.18 in the TensorFlow appliance variant
- Document the protobuf version constraint prominently
- For the PyTorch appliance variant, this is not an issue

**Confidence:** HIGH -- verified in Flower v1.24 changelog.

**Phase:** Phase 1 (appliance packaging).

---

### Pitfall 13: Flower Container UID 49999 Permission Issues

**What goes wrong:** Flower's Docker images run as non-root user `app` (UID 49999). Any files mounted into the container (certificates, state directory, configuration) must be owned by this UID. Standard Docker volume mounts default to root ownership, causing "Permission denied" errors.

**Prevention:**
- Include `chown -R 49999:49999` in contextualization scripts for all Flower-mounted directories
- Document this prominently in the appliance README
- Use named Docker volumes (which handle permissions) instead of bind mounts where possible

**Confidence:** HIGH -- documented in Flower Docker TLS guide (https://flower.ai/docs/framework/docker/enable-tls.html).

**Phase:** Phase 1.

---

### Pitfall 14: Scheduled Actions in VM Templates Within Service Templates

**What goes wrong:** OpenNebula does not support Scheduled Actions in VM Templates that are part of Service Templates. Including them causes "indeterministic behaviour."

**Prevention:** Strip all Scheduled Actions from VM templates before using them in OneFlow service templates. Use OneFlow's own lifecycle management instead.

**Confidence:** HIGH -- documented in OpenNebula OneFlow docs.

**Phase:** Phase 1.

---

### Pitfall 15: gRPC Metadata Header Stripping by Reverse Proxies

**What goes wrong:** Flower changed all gRPC metadata keys from underscores to hyphens in recent versions because some load balancers and reverse proxies silently strip headers containing underscores. If the deployment uses an older proxy configuration or a proxy that still strips certain non-standard headers, Flower communication fails silently.

**Prevention:**
- Test gRPC end-to-end through any proxy/load balancer in the path
- Use direct connections (VPN/overlay network) rather than proxied connections between Flower components
- If proxying is required, ensure HTTP/2 end-to-end support and test with Flower's specific gRPC headers

**Confidence:** HIGH -- mentioned in Flower changelog and gRPC best practices.

**Phase:** Phase 2 (multi-site), where reverse proxies are more likely to be in the network path.

---

## Phase-Specific Warnings

| Phase | Likely Pitfall | Severity | Mitigation |
|-------|---------------|----------|------------|
| Phase 1: Single-Site PoC | GPU passthrough not working on target hardware | Critical | Validate GPU end-to-end before building FL on top |
| Phase 1: Single-Site PoC | TLS certificate automation not working in contextualization | Critical | Prototype cert flow with OneGate early, before other features |
| Phase 1: Single-Site PoC | Appliance image too large for practical marketplace use | Major | Benchmark download + boot time, set a 20GB / 3-minute budget |
| Phase 1: Single-Site PoC | Contextualization script failures with no error output | Major | Implement logging and health checks from day one |
| Phase 2: Multi-Site | SuperLink unreachable from remote sites | Critical | Design cross-site networking (VPN vs public IP) before coding |
| Phase 2: Multi-Site | gRPC connections dropped by firewalls/load balancers | Major | Configure keepalive, test with actual network latency |
| Phase 2: Multi-Site | TLS CA trust across sites | Major | Decide on CA strategy: per-federation CA vs organizational CA |
| Phase 3: Multi-Tenant | Tenant isolation model mismatch (Flower vs OpenNebula) | Critical | Decide per-tenant-SuperLink vs shared-SuperLink in Phase 1 |
| Phase 3: Multi-Tenant | GPU resource contention between tenants | Major | Use MIG or strict PCI passthrough, never shared CUDA context |
| Phase 3: Multi-Tenant | Version skew across tenant federations | Moderate | Marketplace versioning and compatibility matrix |
| Phase 4: Edge/Hybrid | Intermittent connectivity causing training failures | Major | Implement retry logic and checkpoint-based recovery |
| Phase 4: Edge/Hybrid | Non-IID data across heterogeneous edge sites | Major | Default to FedProx, provide convergence monitoring |
| Demo (April 2026) | Everything works on one machine, fails multi-site | Critical | Test the actual demo topology at least 2 weeks before the demo |

---

## Consulting Engagement Priorities (Flower Labs EUR 15K Budget)

Based on the pitfalls identified, these are the highest-value questions to bring to Flower Labs:

1. **Multi-tenant isolation model**: What is Flower's recommended approach for multi-tenant deployments? Is per-tenant SuperLink the only safe option, or are there run-level isolation guarantees?

2. **Version compatibility guarantees**: What is the gRPC protocol stability guarantee between Flower minor versions? Can a v1.24 SuperNode connect to a v1.25 SuperLink?

3. **Certificate automation patterns**: Are there reference implementations for automated TLS setup in cloud environments? Any plans for built-in ACME or cert-manager integration?

4. **gRPC keepalive defaults**: What are the recommended keepalive settings for deployments behind cloud load balancers? Are there plans to make this configurable without code changes?

5. **GPU memory management**: What is the recommended pattern for multi-client GPU sharing in production SuperNode deployments?

---

## Sources

### Official Documentation (HIGH confidence)
- [Flower Network Communication](https://flower.ai/docs/framework/ref-flower-network-communication.html)
- [Flower TLS Configuration](https://flower.ai/docs/framework/how-to-enable-tls-connections.html)
- [Flower Docker TLS](https://flower.ai/docs/framework/docker/enable-tls.html)
- [Flower Architecture](https://flower.ai/docs/framework/explanation-flower-architecture.html)
- [Flower SuperNode Authentication](https://flower.ai/docs/framework/how-to-authenticate-supernodes.html)
- [Flower Changelog](https://flower.ai/docs/framework/ref-changelog.html)
- [Flower Multi-Machine Docker Deployment](https://flower.ai/docs/framework/docker/tutorial-deploy-on-multiple-machines.html)
- [OpenNebula NVIDIA GPU Passthrough](https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/nvidia_gpu_passthrough/)
- [OpenNebula vGPU and MIG](https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/vgpu/)
- [OpenNebula Marketplace Appliances](https://docs.opennebula.io/7.0/product/apps-marketplace/managing_marketplaces/marketapps/)
- [OpenNebula OneFlow Services](https://docs.opennebula.io/7.0/product/virtual_machines_operation/multi-vm_workflows/appflow_use_cli/)
- [OpenNebula OneGate API](https://docs.opennebula.io/6.8/integration_and_development/system_interfaces/onegate_api.html)
- [gRPC Keepalive Guide](https://grpc.io/docs/guides/keepalive/)

### Community and Issue Trackers (MEDIUM confidence)
- [Flower OOM Issue #3238](https://github.com/adap/flower/issues/3238)
- [Flower OOM Forum Discussion](https://discuss.flower.ai/t/how-to-prevent-oom-error-while-training/286)
- [OpenNebula GPU Passthrough Forum Issue](https://forum.opennebula.io/t/gpu-passthrough-no-longer-works-since-vgpu-support-was-added/10855)
- [OpenNebula NVIDIA PCI Issue #5968](https://github.com/OpenNebula/one/issues/5968)
- [gRPC Load Balancer Lessons at Datadog](https://www.datadoghq.com/blog/grpc-at-datadog/)

### Research and Surveys (MEDIUM confidence)
- [Federated Learning Challenges Survey 2025](https://dev.to/lofcz/federated-learning-in-2025-what-you-need-to-know-3k2j)
- [EDPS TechDispatch on Federated Learning](https://www.edps.europa.eu/data-protection/our-work/publications/techdispatch/2025-06-10-techdispatch-12025-federated-learning_en)
- [Non-IID Data in Federated Learning Survey](https://arxiv.org/html/2411.12377v1)
- [Google Cloud FL Architecture](https://cloud.google.com/architecture/cross-silo-cross-device-federated-learning-google-cloud)
