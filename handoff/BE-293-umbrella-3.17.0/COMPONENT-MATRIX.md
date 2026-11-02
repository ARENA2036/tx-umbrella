# Component Matrix: BE-293 Umbrella 3.17.0 (DEV revision 21)

**Reference baselines:**

- Upstream Eclipse Tractus-X Umbrella `umbrella-3.14.0` (`d46d078`)
- ARENA `develop` (`f386f05`, Umbrella 3.14.0)

"DEV" means release `be293-app` revision 21 (`k8s-dev-01`/`be293`), verified read-only on 2026-11-02.

**The target cluster was not inspected. Its current state is UNKNOWN for every row.** The "Fresh target action" column assumes an empty namespace.

**Classification:**

| Class | Meaning |
|---|---|
| NEW | Not in the original Umbrella |
| MODIFIED | Chart and/or image changed |
| CONFIGURATION ONLY | Upstream chart and image, BE-293 values |
| UNCHANGED | As upstream |
| EXTERNAL / SEPARATE RELEASE | Not part of `be293-app` |
| NOT REQUIRED | Disabled in, or absent from, revision 21 |

| Component | Class | Original | DEV revision 21 (chart / image) | Packaged here | Fresh target action | Target state |
|---|---|---|---|---|---|---|
| Umbrella chart | MODIFIED | 3.14.0 | 3.17.0, unversioned build: wallet derive/validate guard, didweb-resolver, BDRS provision and NetworkPolicy, CoreDNS patch (disabled) | `chart/umbrella` (exact) | Install | UNKNOWN |
| EDC Provider / Consumer 1 / Consumer 2 | MODIFIED | connector chart 0.11.1 | tx-data-provider 0.5.0 → dataspace-connector-bundle 1.4.0 → `tractusx-connector` **0.13.0-rc2** (4 local rc2 patches) / private `edc-*-72755ae-r3` (EDC `main` snapshot, no code change) | yes (vendored) | Install; needs Vault policies and `*-connector-crypto` Secrets | UNKNOWN |
| Connector PostgreSQL ×3 | CONFIGURATION ONLY | Bitnami 15.x | `bitnamilegacy/postgresql:15.4.0-debian-11-r45`, 5 Gi each | yes | Install (empty DB) | UNKNOWN |
| IdentityHub | NEW | — (wallet stub) | identity-and-trust-bundle 1.2.0 → `tractusx-identityhub` v0.3.2 (runtime-secret patch) / private `identityhub-3633af-r1` (+ portal-credential-callback extension); PostgreSQL 18.0, 8 Gi | yes | Install, then seeding hook; needs Vault and `be293-identityhub-*` Secrets | UNKNOWN |
| IssuerService | NEW | — | `tractusx-issuerservice` v0.3.2 (runtime-secret patch) / private `issuerservice-3633af-r1` (+ keypair-api patch); PostgreSQL 18.0, 2 Gi | yes | Install; StatusList Ingress required | UNKNOWN |
| BDRS server | NEW | `bdrs-server-memory` 0.5.7 | `bdrs-server` 0.6.0 (secrets patch) / `tractusx/bdrs-server@sha256:e73c…`; PostgreSQL 18.3, 5 Gi | yes | Install, then BDRS setup hook seeds 4 BPN→DID mappings | UNKNOWN |
| `bdrs-server-memory` | NOT REQUIRED | 0.5.7 | 0.6.0, disabled | in package (disabled) | none | — |
| didweb-resolver | NEW | — | Umbrella template / `python:3.12-alpine` | yes | Install | UNKNOWN |
| Wallet stub (`ssi-dim-wallet-stub`) | NOT REQUIRED | 0.1.14 enabled | 0.1.14, disabled | in package (disabled) | none | — |
| Portal chart | MODIFIED | 2.6.0 | 2.6.0 with 6 changed files (IdentityHub settings and `existingSecret`, Connector provisioning, secret preserve) | yes | Install | UNKNOWN |
| Portal Backend: administration, migrations | MODIFIED | `tractusx/portal-*:v2.6.0` | private `portal-administration-cp-933aeeb25-8f847539c0`, `portal-migrations-cp-933aeeb25-8f847539c0` | image refs (mirror) | Install; the migration hook creates the schema | UNKNOWN |
| Portal Backend: processes worker | MODIFIED | v2.6.0 | private `portal-processes-worker-0421c50-security2-r1` | image ref | Install | UNKNOWN |
| Portal Backend: registration, marketplace, notification | MODIFIED | v2.6.0 | private `*-claimfix-r1` (**no source lock**) | image refs | Install | UNKNOWN |
| Portal frontend, registration UI, assets, services, maintenance | UNCHANGED | v2.6.0 / v2.2.2 | upstream tags | image refs | Install | UNKNOWN |
| Portal provisioning migrations | UNCHANGED | v2.6.0 | `tractusx/portal-provisioning-migrations:v2.6.0` | image ref | Hook | UNKNOWN |
| Portal PostgreSQL | CONFIGURATION ONLY | Bitnami 15 | `bitnamilegacy/postgresql:15-debian-11`, 5 Gi | yes | Install (empty DB) | UNKNOWN |
| Central IDP / Shared IDP | MODIFIED | 4.2.1 | 4.2.1 with 2–3 changed files (seeding recovery, TLS CA, connection string, image pull) / `bitnamilegacy/keycloak:25.0.6-debian-12-r0`, `portal-iam:v4.2.0`; private realm-seeding images (2 digests, **no source lock**) | yes | Install; realm seeding Jobs 7 and 13 (B-04) | UNKNOWN |
| BPDM gate / pool / orchestrator / cleaning-dummy | MODIFIED (chart, 1 file: secret preserve) | 6.2.0 / app 7.2.0 | 6.2.0 / `tractusx/bpdm-*:7.2.0` | yes | Install | UNKNOWN |
| Discovery Finder / BPN Discovery | CONFIGURATION ONLY | 0.5.1 / app 0.6.1 | same | yes | Install | UNKNOWN |
| SD-Factory | MODIFIED (chart: secret preserve) | 2.1.34 / 2.1.25 | 2.1.35 / `tractusx/sdfactory:2.1.26` | yes | Install | UNKNOWN |
| Digital Twin Registry | MODIFIED | chart 0.9.0 / upstream 0.9.0 | chart 0.10.0 (digital-twin-bundle 1.2.0) / private `digital-twin-registry-9ac65a-r1` (pagination fix + `sortDirection`); PostgreSQL 10 Gi | yes | Install | UNKNOWN |
| Submodel server (simple-data-backend) | MODIFIED | `tractusx/simple-data-backend:main` | private image (digest), external `submodel-postgresql`, 5 Gi | yes | Install; test-data hook | UNKNOWN |
| smtp4dev | CONFIGURATION ONLY | 3.6.1 | `rnwood/smtp4dev:3.6.1` | yes | Install | UNKNOWN |
| `ssi-credential-issuer`, semantic-hub, pgadmin4, OTel, Jaeger, Prometheus, Loki, Grafana, cert-manager subchart | NOT REQUIRED | present | present in Chart.yaml, disabled | vendored (disabled) | none | — |
| ARENA `onboarding-process-worker` CronJob | NOT REQUIRED | present in ARENA develop | absent from 3.17.0 | no | none | — |
| Vault `be293-vault` | EXTERNAL / SEPARATE RELEASE (NEW) | bundle Vault 0.27.0 | `umbrella-infrastructure` 0.1.0 → vault chart 0.30.1 / `hashicorp/vault:1.20.1`, Raft, 2 Gi | `charts/umbrella-infrastructure` + values | Install **before** `be293-app`; bootstrap per VAULT-CONTRACT | UNKNOWN |
| Ingresses `be293-identityhub-legacy-did`, `be293-identityhub-did-documents`, `be293-issuer-legacy-did`, `be293-issuer-statuslist` | EXTERNAL / SEPARATE RELEASE (non-Helm) | — | live objects (2 own the TLS certificates and DNS records) | `manifests/1[0-3]-*.yaml` | Apply after `be293-app` | UNKNOWN |
| Ingress `be293-ingress-dns-test` | NOT REQUIRED | — | DNS test only | no | none | — |
| Connector Provisioner (`be293-connectors` ns), tenant connectors `be293-onb0003-edc`, `edc-bpnl00000000015g` | NOT REQUIRED for this baseline (EXTERNAL) | — | separate releases, source uncommitted | **no** (B-10) | none, unless the owner decides otherwise | — |
| ingress-nginx, cert-manager + ClusterIssuer, ExternalDNS, default StorageClass | EXTERNAL (platform) | — | present on DEV | no | Platform prerequisite | UNKNOWN |

## Identities preserved unchanged (from the revision 21 overlay)

| Role | BPN | Participant context | DID (DNS suffix replaced per environment) |
|---|---|---|---|
| Operator | BPNL00000003CRHK | `operator-bpnl00000003crhk` | `did:web:identity-hub.be293.dev.<suffix>:BPNL00000003CRHK` |
| Issuer | BPNL00000003CRHK | `issuer-bpnl00000003crhk` | `did:web:issuer-service.be293.dev.<suffix>:BPNL00000003CRHK` |
| Provider | BPNL00000003AYRE | `provider-bpnl00000003ayre` | `did:web:identity-hub.be293.dev.<suffix>:BPNL00000003AYRE` |
| Consumer 1 | BPNL00000003AZQP | `consumer-bpnl00000003azqp` | `did:web:identity-hub.be293.dev.<suffix>:BPNL00000003AZQP` |
| Consumer 2 | BPNL00000003AVTH | `consumer-bpnl00000003avth` | `did:web:identity-hub.be293.dev.<suffix>:BPNL00000003AVTH` |
