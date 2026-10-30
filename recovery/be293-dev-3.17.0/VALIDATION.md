# Validation report: BE-293 Umbrella 3.17.0 sanitized baseline

- **Date:** 2026-10-30
- **Helm:** v4.3.0
- **Reference:** the deployed DEV Helm release (revision 21) and its user values.
  The cluster was accessed read-only for the comparison. The reference data is
  not part of this repository.

## 1. Recovery fidelity (before sanitization)

| Check | Result |
|---|---|
| Templates and files vs the release record | 19/19 and 6/6 identical. Two templates later lost one trailing space each, with no render effect. |
| `Chart.lock` digest vs the release lock digest | identical |
| Chart default values vs the release's stored defaults | no changed or missing keys |
| Render vs the deployed release | 231/231 resources, identical images and env var names; 181/199 non-Secret objects byte-identical; every other difference explained |

## 2. Sanitization

| Item | Change |
|---|---|
| Chart defaults (`chart/umbrella/values.yaml`) | 120 credential literals replaced with labeled placeholders |
| DEV overlay → `values/values-be293-dev.example.yaml` | 8 inline credentials and 1 credential-derived Vault alias replaced with placeholders; DNS suffix → `example.invalid` (160×); private image repository → `registry.example.invalid/be293/be293-images` (29×); registry host fields → `registry.example.invalid` (3×). All other configuration is unchanged. |
| `templates/_wallet-validate.tpl` | The hard-coded approved image repository became the value `be293.privateImages.approvedRepository`. The guard still fails on a missing or mismatched repository (negative tests pass). |
| `charts/identity-and-trust-bundle-1.2.0.tgz` | Rebuilt: 7 credential defaults replaced with placeholders, including 1 Vault alias |

**Round trip.** `tools/apply_environment.rb` with the real environment values
regenerates an overlay that is semantically identical to the deployed overlay.
The only addition is `approvedRepository`, which is equal to `repository`.

## 3. Offline Helm checks (example overlay + secrets template)

| Check | Result |
|---|---|
| `helm lint` | 1 chart linted, 0 failed |
| `helm template` | exit 0, 231 documents |
| Kind/name inventory vs the deployed release | 231 = 231, no differences |
| Env var names and sources | 0 differences |
| Container images | 26 of 94 lines differ, only by registry/repository (example registry); tags and digests unchanged |
| Non-Secret object content | 155/199 identical |

The differing fields in the other 44 objects break down as follows.

| Cause | Fields |
|---|---|
| Example DNS/registry identifiers | 196 |
| Credential placeholders | 16 |
| Checksum annotations over changed inputs | 6 |
| Objects copied from the live cluster via Helm `lookup` (4 realm-seeding Jobs) | 100 |
| Unexplained | 0 |

## 4. Secret and identifier scan

Scope: every file, including all 22 dependency packages and their nested
packages, unpacked recursively. The documentation is included.

| Check | Result |
|---|---|
| Real private keys (PEM with key body) | 0. The 20 PEM blocks are commented or README examples in vendor charts. |
| JWTs, private JWKs, docker auth, cloud tokens | 0 |
| The deployed DEV credentials (overlay inline values and all namespace Secret values, compared in memory) | 0 high-entropy matches. Low-entropy dictionary words that also appear as vendor defaults are not treated as findings. |
| Internal environment identifiers (private DNS zone, private registry account, cluster endpoint, personal paths, email addresses) | 0 |

**Residual non-secret names.** These platform contract names are kept because
the guardrails rely on them: deployment profile `k8s-dev-01`, namespace
`be293`, ClusterIssuer `letsencrypt-dev`, StorageClass `premium-perf1-stackit`,
and the Kubernetes Secret names listed in `README.md`. Tractus-X test BPNs and
test company IDs are public upstream test data.

## 5. Dependency provenance

Compared with the official Eclipse Tractus-X chart index.

| Packages | Status |
|---|---|
| bdrs-server-memory 0.6.0, bpndiscovery 0.5.1, discoveryfinder 0.5.1, semantic-hub 0.5.0, ssi-credential-issuer 1.4.0, tractusx-identityhub-memory v0.3.2 | Byte-identical to the published releases |
| bpdm 6.2.0, centralidp 4.2.1, sharedidp 4.2.1, portal 2.6.0 | Locally modified forks of the published releases (1, 2, 3 and 6 changed files). The changes add Helm `lookup` recovery, IdentityHub Portal settings and Secret references; they add no credential literals. |
| bdrs-server 0.6.0, sdfactory 2.1.35, tractusx-identityhub v0.3.2 | Differ from the published digests. Content was not compared, because the published archives were not reachable. |
| identity-and-trust-bundle 1.2.0, tx-data-provider 0.5.0 | BE-293 forks with no published counterpart (identity-and-trust-bundle rebuilt as described above) |
| opentelemetry-collector, jaeger, prometheus, loki, grafana, cert-manager, pgadmin4 | Not verified. All are disabled in the DEV overlay. |

## 6. Not verified

- That a filled-in private overlay reproduces the deployed Secret contents.
- Stateful systems (Vault, databases, Keycloak, IdentityHub) and container image
  build sources.
- Any deployment or upgrade. None was performed.
