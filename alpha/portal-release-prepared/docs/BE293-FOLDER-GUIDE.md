# BE-293 Alpha release package: folder guide

Location: `~/Projects/ARENA2036/BE293_ALPHA/tx-umbrella/alpha/portal-release-prepared`

This folder contains everything needed to operate the BE-293 Portal on STACKIT Alpha (context `alpha`,
namespace `be293`, Helm release `be293-portal`): configuration, guarded operator scripts, offline safety gates,
tests, documentation and CI material. Next steps and procedures: [BE293-RUNBOOK-NEXT-STEPS.md](BE293-RUNBOOK-NEXT-STEPS.md).

## One dependency outside this folder

| Path | Why |
|---|---|
| `../../handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz` | The Portal Helm chart. Render, diff, install, recovery and upgrade all use it (checksum-pinned). It is tracked in Git in `BE293_ALPHA/tx-umbrella`. |

Operator machine also needs: `~/.kube/alpha.yaml`, `helm`, `kubectl`, `ruby`, `jq`.

## Top-level files (the release configuration)

| File | Purpose |
|---|---|
| `values-be293-portal.yaml` | Main Helm values: hosts, integrations, image pins (`backend.*.image`), IdentityHub, BPDM, mail settings. |
| `values-be293-portal.alpha-release.yaml` | Alpha overlay: Ingress (TLS, cert-manager), in-cluster DID resolver address. |
| `values-be293-portal.alpha-retention.yaml` | Data-protection overlay: Secrets and PVC are kept, maintenance CronJob suspended. |
| `values-be293-portal.alpha-smtp4dev.yaml` | Portal mail of the processes-worker goes to the smtp4dev test sink (shared-realm SMTP stays Office 365). |
| `images.lock.yaml` | Single source of image provenance: deployed pins (`rebuilt`), published-but-not-deployed builds, upstream images. Must match the values. |
| `digests.txt` | Recorded image digests. |
| `expected-drift.alpha.yaml` | Reviewed differences between the rendered release and live Alpha. Any other drift stops diff/recovery/upgrade. |
| `secrets-contract.yaml` | Which keys each be293 Secret must contain (names and rules only, never values). |
| `expected-inventory*.txt` | Expected list of rendered objects (offline gate input). |
| `alpha-service-map.yaml` | Map of services and in-cluster addresses. |
| `networkpolicies-be293-portal*.yaml` | NetworkPolicies for be293 (applied separately from Helm). |
| `did-resolver-be293.alpha.yaml` | Self-hosted did:web resolver (Deployment, Service, NetworkPolicy), not part of the Helm release. |
| `smtp4dev-be293.alpha.yaml` | smtp4dev test mail sink, not part of the Helm release. |
| `README.md`, `README-ALPHA-RELEASE.md` | Package overview and release background (secrets handling, decisions, open blockers). |

## `tools/` — operator scripts and offline gates

Shell scripts talk to the cluster only through guarded wrappers (explicit kubeconfig/context/namespace, an allow-list
of verbs). Scripts that change something default to a read-only dry run and need `--execute` plus a typed confirmation.

**Daily operation (read-only)**

| Script | Purpose |
|---|---|
| `smoke-be293.sh` | Post-upgrade smoke test: release state, readiness, image pins, configuration, Ingress, public routes, logs, resolver. |
| `helm-diff-be293.sh` | Read-only diff of the release against live Alpha, with the expected-drift gate. |
| `credential-status-be293.sh` | BPN/Membership credential checklist state and verdict for one application. |
| `bpdm-endpoint-be293.sh` | BPDM endpoint check; `--bpn-status` shows BPN steps per application. |
| `diagnose-invitation-be293.sh` | Diagnosis of "Invite a New Partner" processes. |
| `health-check-be293.sh` | Anonymous external HTTPS health check. |
| `alpha-preflight.sh` | Read-only preflight of the Alpha environment. |

**Changes (guarded, approval required)**

| Script | Purpose |
|---|---|
| `upgrade-be293.sh` | Worker-only Helm upgrade (current: revision 4 -> 5): gates, dry run, snapshot, `helm upgrade --no-hooks`, verification. |
| `recover-be293.sh` | One-time recovery from the failed revision 1 (used for revision 2; refuses to run now). |
| `install-be293.sh` | Guarded first installation (historical). |
| `did-resolver-be293.sh` | Deploy/verify/diff the DID resolver. |
| `smtp4dev-be293.sh` | Deploy/verify the smtp4dev sink. |
| `create-be293-secret.sh` | Create one contract Secret; credentials typed at a hidden prompt. |
| `idp-prefix-be293.sh`, `keycloak-k1.sh` | Keycloak IdP prefix and shared-client changes (blocker K1). |

**Offline gates and helpers (no cluster access)**

| Script | Purpose |
|---|---|
| `render-release.sh`, `render.sh` | Offline render plus all gates (expect seven PASS lines). |
| `validate_render.rb`, `validate_ingress.rb`, `validate_retention.rb`, `validate_smtp4dev.rb`, `validate_did_resolver.rb`, `check_package.rb` | The individual gates. |
| `compare_release_live.rb` | Rendered-vs-live comparison (field ownership, Secret key check without values, expected drift). |
| `verify_release_retention.rb` | Retention check of a stored release manifest. |
| `check_secret_contract.rb`, `build_secret_manifest.rb` | Secret contract check and manifest builder. |
| `bpdm_openapi.rb` | Checks the live BPDM API contract against the fields the backend uses. |
| `keycloak_alias_check.rb`, `env_patch.rb`, `pin_source.rb`, `record_portal_images.rb`, `build-images.sh` | Helpers for Keycloak checks, env patches, source pinning and image recording. |
| `lib/be293-db.sh` | Read-only SQL helper (`psql_ro`) against the be293 PostgreSQL. |

## `tests/` — automated tests for the tools

Ruby/Minitest tests with stubbed `kubectl`/`helm` (no cluster). They prove that scripts stay read-only, refuse
unsafe flags, stop on unreviewed drift and never print secret values. `support/` holds pinned fixtures.
Run all: `for t in tests/test_*.rb; do ruby "$t"; done` (214 runs, 0 failures at revision 5).

## `docs/` — documentation

| File | Purpose |
|---|---|
| `BE293-RUNBOOK-NEXT-STEPS.md` | Step-by-step procedures, approvals, emergency recovery. |
| `BE293-SESSION-REPORT-2026-11.md` | What was diagnosed and changed in November 2026. |
| `BE293-FOLDER-GUIDE.md` | This guide. |

## `ci/` — image builds and backend patches

| File | Purpose |
|---|---|
| `be293-portal-images.yml` | Copy of the isolated image-build workflow (lives in `ARENA2036/tx-umbrella`, branch `fix/be293-await-worker-image`). |
| `*.patch` | Backend/frontend fixes as reviewable patches (DID retrigger, credential await, maintenance Dockerfile, Pkcs CVE, frontend retrigger). |
| `archive/` | Historical one-off helpers (`prepare-portal-backend-*.sh`, `run-be293-build-only.sh`, an old workflow patch). Not used by any tool; some point to worktree folders that were removed. |

## `bruno/` — API collection

`issuer-service-readonly/`: Bruno collection for the IssuerService admin API (read-only checks of credential
definitions, attestations and holders) and the Portal API with operator login (checklist; guarded retrigger
requests). Keys and tokens are kept by Bruno locally, never in these files. See its `README.md`.

## `helm-plugins/` — Helm post-renderer

`be293-retention/`: post-renderer used by every render and upgrade. It enforces data protection (Secrets and the
PostgreSQL PVC are never deleted, maintenance CronJob suspended).

## `.evidence/` — snapshots (do not commit)

Pre-upgrade snapshots per revision (`pre-revision-N-<time>/`: live objects, ReplicaSets, Helm history, image lists)
and build logs. Used for rollback and audits. Contains full workload specifications: keep it out of Git and do not share.

## `.claude/` — local tool settings

Local tool settings on the operator machine. Not part of the release; git-ignored.

## Housekeeping

- `.gitignore` excludes `.evidence/` and `.claude/`. The package is committed on branch `feat/BE-293-alpha-release-package` in `ARENA2036/tx-umbrella`.
