# Marketplace Appliance Files

OpenNebula marketplace YAML files for distributing Flower FL as a one-click appliance.

## How it works

When a user exports **Service Flower FL 1.25.0** from the marketplace, OpenNebula
automatically cascades and imports all dependent VM templates and disk images:

```
Service Flower FL 1.25.0           (SERVICE_TEMPLATE)   <- user exports this
  |-- Flower SuperLink 1.25.0      (VMTEMPLATE)         <- auto-imported
  |   +-- Flower SuperLink 1.25.0 OS disk  (IMAGE)      <- auto-imported
  +-- Flower SuperNode 1.25.0      (VMTEMPLATE)         <- auto-imported
      +-- Flower SuperNode 1.25.0 OS disk  (IMAGE)      <- auto-imported
```

After export, the user opens the service template in Sunstone, fills in the
network and any desired configuration (framework, rounds, strategy), and clicks
Instantiate. The cluster deploys automatically.

## Files

| File | Type | Name |
|------|------|------|
| `2b2fbd55-751a-4b58-b698-692b21c1b06f.yaml` | IMAGE | Flower SuperLink 1.25.0 OS disk |
| `54dc63b2-07dc-4469-8ec9-b31a6be2f926.yaml` | IMAGE | Flower SuperNode 1.25.0 OS disk |
| `49da1d48-717e-44c2-856b-850687afd73a.yaml` | VMTEMPLATE | Flower SuperLink 1.25.0 |
| `b4d08fae-f02d-4061-b130-870e4a9a93f8.yaml` | VMTEMPLATE | Flower SuperNode 1.25.0 |
| `8b437ffe-7b90-4dc0-a453-f0646b11ab09.yaml` | SERVICE_TEMPLATE | Service Flower FL 1.25.0 |

## Before publishing

The IMAGE files have placeholder values that must be filled before publishing:

1. **`url`** -- QCOW2 download URL (e.g., CloudFront CDN link)
2. **`checksum.md5`** and **`checksum.sha256`** -- checksums of the published QCOW2 files
3. **`logo`** -- upload `flower.png` to the marketplace logo store

Generate checksums after uploading:

```bash
md5sum flower-superlink-1.25.0.qcow2
sha256sum flower-superlink-1.25.0.qcow2
md5sum flower-supernode-1.25.0.qcow2
sha256sum flower-supernode-1.25.0.qcow2
```

## Format reference

These files follow the OpenNebula marketplace YAML format used by all official
appliances (OneKE, Lithops, RabbitMQ, etc.). See the
[marketplace-wizard](https://github.com/OpenNebula/marketplace-wizard) repository
for the tooling that validates and publishes these files.
