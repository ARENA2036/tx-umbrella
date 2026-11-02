# BE-293 Umbrella 3.17.0: Deployment Handoff Package

**Purpose.** Reproduce the working BE-293 DEV baseline on another Kubernetes cluster. The baseline is the Helm release `be293-app`, chart `umbrella-3.17.0`, **revision 21**, in namespace `be293` on context `k8s-dev-01`.

**Status: READY FOR ENGINEERING REVIEW. NOT READY TO INSTALL.** Install readiness depends on the external inputs and decisions in [BLOCKERS.md](BLOCKERS.md).

This package changes no versions. It does not upgrade EDC (it stays on chart `0.13.0-rc2`), it does not refactor the charts, and it does not change any DID, BPN, participant context ID or image. Everything here is either:

- copied byte for byte from a verified source,
- reconstructed from read-only cluster evidence, or
- written new: documentation, tooling, and one optional overlay.

[ARTIFACT-MANIFEST.md](ARTIFACT-MANIFEST.md) records the source and SHA-256 of every file.

## What a successful render proves, and what it does not

All checks were run offline on 2026-11-02 (see [§ Verification](#verification)). They show that the packaged chart, given the sanitized overlay and synthetic credentials, renders the **same 231 objects** as DEV revision 21, with the same:

- images (registry normalized)
- env var names
- Secret references
- PVC templates
- hooks

They do **not** prove that an install works. Installing needs:

- a prepared platform
- Vault initialized with the right policies
- pre-provisioned Secrets
- mirrored images
- successful post-install hooks

None of these was exercised.

## What works on DEV, and what a fresh target needs

| Area | On DEV (revision 21) | On a fresh target |
|---|---|---|
| Helm release `be293-app` | Running; built up over 21 revisions plus live repairs | One `helm install` of this chart. All post-install hooks run **once** (§ Hooks). |
| Vault | `be293-vault` initialized, policies and tokens repaired live on 2026-10-22 | Install the chart, then initialize and unseal, then create KV, role and policies per [docs/VAULT-CONTRACT.md](docs/VAULT-CONTRACT.md). There is **no packaged automation** (B-03). |
| Identities (DIDs, credentials) | Seeded and repaired; 16 credentials `ISSUED` on 2026-10-22 | Seeded fresh by the chart's IdentityHub seed hook. DIDs contain the DNS name, so a new domain means new DIDs (B-05). |
| Keycloak realms | Seeded by revisions 7 and 13, then changed by live scripts | Seeded from values. Live-only realm changes on DEV are **not reproduced** (B-09). |
| DID and StatusList routes | 4 Ingresses outside Helm | `manifests/1[0-3]-*.yaml`, applied after the release (§ Install) |
| Portal database | Connector-provisioning migration applied by a manual Job | Applied by the `portal-migrations` hook image (`cp-933aeeb25`) |

## Layout

| Path | Content |
|---|---|
| `chart/umbrella/` | Umbrella 3.17.0, an exact copy of the committed `recovery/be293-dev-3.17.0/chart/umbrella` (50 files, 22 vendored dependency packages, `Chart.lock`). Credential defaults are labelled placeholders. |
| `charts/umbrella-infrastructure/` | The separate Vault release chart (0.1.0; Vault chart 0.30.1, external-secrets 0.18.2 disabled) |
| `values/values-be293-dev.example.yaml` | Sanitized revision 21 overlay. Identifiers use `example.invalid`; 10 credential placeholders. |
| `values/values-be293-dev.secrets.example.yaml` | Template with **every** credential placeholder that reaches the render (125) |
| `values/values-be293-identityhub-superuser-secretref.yaml` | OPTIONAL, recommended: super-user and admin API keys from Secret `identityhub-superuser` |
| `values/values-be293-vault.example.yaml` | Values for the `be293-vault` release (no credentials) |
| `manifests/` | 4 non-Helm Ingresses for DID documents and the StatusList (example domain) |
| `inventory/` | Expected inventories of revision 21 and `be293-vault`; image inventory and source lock |
| `docs/` | Secret contract and Vault bootstrap contract |
| `tools/` | Offline tooling (Ruby ≥ 2.6, Helm ≥ 3.14; validated with Helm v4.3.0). The tools force UTF-8, so they work with `LANG` unset. `generate_manifest.rb` is for maintainers: it re-compares the copies with `recovery/` and the source checkout. |
| `docs/ISOLATED-CLUSTER-TEST-PLAN.md` | Acceptance test for an empty cluster. The only way to prove that this package installs. |
| `COMPONENT-MATRIX.md`, `DEPLOYMENT-CHECKLIST.md`, `BLOCKERS.md`, `ARTIFACT-MANIFEST.md` | Handoff documents |

## Prerequisites (target cluster; current state UNKNOWN)

- **Kubernetes.** DEV runs 1.35. The package needs no cluster-scoped resources: the revision 21 render contains no ClusterRole, CRD or webhook.
- **Namespace `be293`.** Required: the chart guard rejects any other namespace while `be293.deploymentProfile: k8s-dev-01` is set. The profile value is a guard key, not a cluster name; keep it to reproduce revision 21 exactly.
- **Storage.**
  - A **default StorageClass**: 14 PostgreSQL StatefulSets render PVC templates without `storageClassName`.
  - `premium-perf1-stackit` is named in `be293.platform.storageClass`, in two persistence settings of the overlay, and in the Vault values.
  - Capacity: 11 × 5 Gi + 10 Gi (DTR) + 8 Gi (IdentityHub) + 2 Gi (IssuerService), plus 2 Gi for Vault.
- **ingress-nginx** with class `nginx` and regex support (`use-regex`).
- **cert-manager** with a ClusterIssuer. The overlay and manifests name `letsencrypt-dev`.
- **DNS** for every host. The Ingress annotations expect ExternalDNS (`external-dns.alpha.kubernetes.io/hostname`).
- **Hostname pattern.** The overlay keeps the DEV naming pattern `<service>.be293.dev.<suffix>` and `<service>-be293.dev.<suffix>`; `BE293_DNS_SUFFIX` replaces only `<suffix>`.
- **Registry.** All images (see `inventory/IMAGE-INVENTORY.yaml`) mirrored **by digest** into an approved registry, plus the pull Secret `be293-dockerhub-pull`.
- **Secrets.** Every pre-provisioned Secret in [docs/SECRETS.md](docs/SECRETS.md) §A.
- **Vault.** Per [docs/VAULT-CONTRACT.md](docs/VAULT-CONTRACT.md).

## Configuration

Values are applied in this order; the last `-f` wins.

1. `chart/umbrella/values.yaml`. Applied automatically; do not edit it.
2. The environment overlay `values/<env>.private.yaml`, generated from the example. It is git-ignored.
3. The secrets overlay `values/<env>.secrets.yaml`, filled from the approved secret store. It is git-ignored.
4. Optional: `values/values-be293-identityhub-superuser-secretref.yaml`.

```bash
cd handoff/BE-293-umbrella-3.17.0
export BE293_DNS_SUFFIX='<target dns suffix>' BE293_REGISTRY_HOST='<registry host>' \
       BE293_IMAGE_REPOSITORY='<registry host>/<namespace>/be293-images'
ruby tools/apply_environment.rb values/values-be293-dev.example.yaml values/target.private.yaml
for m in manifests/*.yaml; do ruby tools/apply_environment.rb "$m" "manifests/$(basename "$m" .yaml).private.yaml"; done
cp values/values-be293-dev.secrets.example.yaml values/target.secrets.yaml && chmod 600 values/target.secrets.yaml
# fill every <<SET-FROM-SECRET-STORE:...>> in values/target.secrets.yaml; keep all list entries
```

**Rules:**

- **Every placeholder must be replaced.** Lint and render also succeed with placeholders left in, and the literal placeholder text would then become the password. `tools/check_placeholders.rb` must report `placeholders=0 example-identifiers=0` before any install.
- **OAuth client secrets must match.** The same secret appears in Keycloak realm seeding and in its consumer; see [docs/SECRETS.md](docs/SECRETS.md) §B.
- **Leave these empty:** `wallet.participants.*.vaultToken` and `wallet.identityHub.shared.vaultToken`. The guard enforces this.
- **Never** use `helm --debug`, and never write a render with real values to disk or logs.

## Install order (after BLOCKERS are resolved; not executed)

1. Platform prerequisites (above).
2. `helm install be293-vault charts/umbrella-infrastructure -n be293 -f values/values-be293-vault.example.yaml` (adapt storage first).
3. Vault bootstrap per [docs/VAULT-CONTRACT.md](docs/VAULT-CONTRACT.md): init, unseal, KV-v2 `secret/`, role `be293-runtime`, 6 policies, 6 runtime tokens.
4. Create all pre-provisioned Secrets ([docs/SECRETS.md](docs/SECRETS.md) §A), including `identityhub-superuser` if you use the optional overlay.
5. Run a server-side dry run, which needs the API server but persists nothing:

   ```bash
   helm install be293-app chart/umbrella -n be293 \
     -f values/target.private.yaml -f values/target.secrets.yaml [-f values/values-be293-identityhub-superuser-secretref.yaml] \
     --dry-run=server >/dev/null
   ```

6. `helm install be293-app …` with the same files, plus `--wait --wait-for-jobs --timeout 45m`. The post-install hooks run then (§ Hooks). Helm applies `--timeout` to **each hook**, and the default of 5 minutes is too short for a cold start. A timed-out hook marks the release `failed`, as happened to DEV revision 12.
7. `kubectl apply -f manifests/*.private.yaml` (the 4 Ingresses; their backends are Services of `be293-app`).
8. Run acceptance per [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) § E.

### Hooks and seeding on an empty cluster

| Object | Hook | Behaviour on a fresh install | Risk |
|---|---|---|---|
| `secret-{bpndiscovery,discoveryfinder}-postgres-init` | pre-install | Creates database init Secrets | Low |
| `Job/be293-app-portal-portal-migrations` | post-install, post-upgrade | Runs the Portal EF migrations, including the Connector-provisioning tables | Applies schema to an empty DB. On upgrades it re-runs. |
| `Job/be293-app-portal-provisioning-migrations` | post-install, post-upgrade | Upstream provisioning migrations | Low |
| `Job/be293-app-umbrella-post-install-bdrs-setup` | post-install, post-upgrade | Writes the BDRS Vault aliases and seeds BPN→DID mappings | Needs Vault policies and tokens first |
| `Job/be293-app-dataprovider-post-install-identityhub-seed` (+ SA, Role, RoleBinding) | post-install, post-upgrade | Creates participant contexts, keys and STS secrets; requests credentials | Needs Vault first. Not idempotent across `holderPid` (B-04). It failed on DEV on 2026-10-16. |
| `Job/be293-app-dataprovider-post-install-testdata` | post-install | Uploads the synthetic test data | Low |
| `Job/be293-app-{centralidp,sharedidp}-realm-seeding-7` and `-13` | none (plain Jobs) | **Both generations are created and run concurrently**, with different pinned seeding images | Revision 7 failed on DEV (B-04) |

Hook ordering (from the render):

- **Weight −5:** Portal migrations, provisioning migrations and BDRS setup start together. The Portal migration Jobs have **no** database wait and rely on Job retries.
- **Weight −3:** IdentityHub seed (`backoffLimit: 2`; its Role can read pod logs).
- **Weight −2:** test data.

Hooks without a delete policy get Helm's default `before-hook-creation`. The realm-seeding Jobs are ordinary resources, with a `wait-for-keycloak` init container. **An install on an empty cluster has not been proven.** Run [docs/ISOLATED-CLUSTER-TEST-PLAN.md](docs/ISOLATED-CLUSTER-TEST-PLAN.md) first.

On DEV, revisions 14–21 most likely ran with `--no-hooks`; the hook Jobs date from 2026-10-16. This is INFERRED. Any later `helm upgrade` without `--no-hooks` re-runs the seed and setup hooks.

## Verification

Run `bash tools/verify_package.sh` (offline). Results on 2026-11-02:

| Check | Result |
|---|---|
| Packaged chart vs committed recovered chart | 50/50 files, identical SHA-256 |
| `helm dependency list` | 26 entries resolved from vendored packages. `tractusx-identityhub v0.3.2` reports `unpacked`; identical in the committed recovered chart; disabled alias. |
| `helm lint` (example + synthetic secrets; strict with private env and SecretRef overlay) | 0 failed |
| Render vs DEV revision 21 inventory | **231 = 231 objects, 0 differences** (images, env names, Secret refs, PVC templates, hooks) |
| Render with the SecretRef overlay | 6 intended differences (`identityhub-superuser` references) |
| Vault chart vs live `be293-vault` (manifest + hooks) | 6 = 6, 0 differences |
| Ingress manifests vs live objects (domain normalized) | 4/4 identical |
| Placeholder coverage (synthetic secrets) | 0 placeholders remain |
| Guardrails (missing `approvedRepository`, wrong namespace) | Both rejected |
| Fresh clone of the committed set (throwaway repo with the repository root `.gitignore`; isolated `HOME`, empty Helm cache, config and data, `LANG` unset) | All checks pass; 88 files, nothing taken from outside the package. A locale dependency in the Ruby tools was found and fixed (2026-11-02). |
| Paths referenced by the package docs | All exist. One dead relative link remains inside the vendored upstream `chart/umbrella/README.md`; it is left unchanged to keep the chart byte-exact. |
| Real DEV credentials in the package (in memory, high-entropy values from the revision 21 values and the source chart defaults) | **0 occurrences** of the DEV overlay credentials. The only matches are upstream public defaults inside vendored charts, plus one dictionary word that is also a placeholder label. During packaging, the check caught one Vault alias name derived from the DEV STS client secret, copied from the DEV tooling into a draft of `docs/VAULT-CONTRACT.md`. It was replaced by a reference (S-07). |
| Pattern scan (all files, packages unpacked) | 20 PEM private-key blocks, all inside vendor README or example values (as in `recovery/VALIDATION.md`). No JWT, private JWK or docker auth. |
