# BE-293 Portal on Alpha (`be293`): local deployment package

Standalone Helm release `be293-portal` of the BE-293 Portal in namespace `be293`, reusing central services
from `release26-09` (Keycloak, IdentityHub, IssuerService, BDRS, BPDM, SD-Factory). The old Portal and its
database are never referenced, and the EDC connectors in `connector` are untouched.
**Nothing here has been applied to any cluster, built into a registry or pushed.**

## Files

| File | Purpose |
|---|---|
| `values-be293-portal.yaml` | Alpha values for the vendored chart `handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz` (sha256 `a17ab650…5ad1e09`) |
| `networkpolicies-be293-portal.yaml` | Default-deny plus explicit allows. The database port is reachable only inside `be293`, and egress rules use pod (container) ports |
| `alpha-service-map.yaml` | Confirmed `release26-09` Services: Service port, resolved container port, pod selector, evidence |
| `secrets-contract.yaml` | Secret names, keys, client IDs, reuse options and owners (no values) |
| `images.lock.yaml` | Image provenance, verified build facts, CI status, digests to fill |
| `expected-inventory.txt` | Reviewed list of the 29 rendered objects |
| `tools/render.sh` | Offline lint, render and gates (`KUBECONFIG=/dev/null`, throwaway Helm home, render deleted on exit) |
| `tools/validate_render.rb` | Gates: scope, hooks, DB targets, images, shared-service config, secrets, securityContext, NetworkPolicies, service map, inventory |
| `tools/build-images.sh` | Local build of the 8 backend images from a `git archive` of the pinned commit. Dry run by default, `--execute` to build, no push option |
| `tools/check_package.rb` | Static checks: duplicate YAML keys; workflow, lock and values consistency; workflow guardrails; Secret names declared |
| `ci/be293-portal-images.yml` | **Proposal** (inactive): isolated CI build of the 8 images. See "Isolated CI build" |
| `tests/test_validate_render.rb`, `tests/test_check_package.rb` | Unit tests for every gate plus offline integration renders |

```bash
bash alpha/portal/tools/render.sh offline          # placeholders allowed, reported
bash alpha/portal/tools/render.sh release          # fails until every placeholder is resolved
ruby alpha/portal/tests/test_validate_render.rb
bash alpha/portal/tools/build-images.sh            # dry run; add --execute where Docker + NuGet are reachable
```

## Current status (2026-11-04)

| Check | Result |
|---|---|
| `helm lint` / offline render | exit 0, 29 objects, all gates PASS |
| Release-mode render | exit 1, as intended (placeholders remain) |
| Gate test suite | see the last run in the report; 0 failures expected |
| IdentityHub/IssuerService API compatibility (A1–A5) | Compatible: v0.4.1 / chart v0.4.2 bundle EDC 0.17.0, the same controllers the Portal targets |
| Frontend v2.6.0 vs backend `f5badda90` API | Compatible: the only removed endpoint is not used by frontend v2.6.0 |
| BE-293 migrations in source | Both present in `PortalBackend.Migrations` at `f5badda90`, no compile exclusions, snapshot includes connector provisioning |
| Local image build | **BLOCKED**: the sandbox denies `api.nuget.org` and there is no Docker daemon. Not an auth, feed or dependency problem |
| CI image build | The existing portal-backend workflows are unsuitable: only one targets `arena2036.azurecr.io`, and it tags `latest`. The isolated proposal `ci/be293-portal-images.yml` is ready for review but not activated |
| Package integrity (`check_package.rb`) | 6 YAML files, no duplicate keys; workflow, lock and values consistent; all referenced Secrets and keys declared |

## Source re-pin for the Pkcs CVE and maintenance fix (pending)

- **Run 41854108371:** 8/8 builds, Trivy and the migrations check all passed. Trivy reported HIGH `CVE-2026-84008` in `portal-processes-worker`.
  - Chain: `Processes.Worker` → `Mailing.Executor` → `Mailing.SendMail` → `MimeKit` 4.13.0 → `System.Security.Cryptography.Pkcs` 8.0.1.
  - None of the other seven images contains this chain.
- **Fix:** `ci/portal-backend-pkcs-cve-2026-84008.patch` pins Pkcs 8.0.2. Together with `ci/portal-backend-maintenance-dockerfile.patch`, it goes into a new portal-backend commit.
- **Run locally (needs NuGet access):** `ci/archive/prepare-portal-backend-fix.sh`. It creates a worktree and branch, applies both patches, restores, checks that Pkcs is 8.0.2, builds the 8 projects, runs the tests and commits. It never pushes.
- **Then re-pin** with `ruby tools/pin_source.rb <NEW_SHA> --upstream-dockerfile-fixed`. This updates the workflow `SOURCE_COMMIT`, removes the CI "Prepare Dockerfile" step, and sets the lock and values tags to the CI scheme `be293-<full sha>`. The previous `be293-f5badda90` short tags never matched what CI pushes.

## Isolated CI build: run results and pending fix

- **Status:** the workflow was merged via PR #239 (`develop` at `7bd43c3`).
- **First build-only run `41849663453`:**
  - 7 of 8 builds succeeded, and the migrations image contains both BE-293 migrations.
  - **The maintenance build failed.** `docker/Dockerfile-maintenance-service` at `f5badda90` does not copy `src/onboarding/Onboarding.WalletProvider`. `ApplicationChecklist.Library` references it since BE-293, so publish fails with CS0234/CS0246. It is the only project missing from the 23-project closure.
  - **The scan failed in the 7 built jobs.** trivy-action v0.32.0 defaults to Trivy v0.64.1, whose GitHub release no longer exists: releases v0.27–v0.69.1 were removed, only the tags remain.
- **Fix prepared, not yet in a PR** (`ci/be293-portal-images.yml`, +46/−3 vs `develop`):
  - A checksum-guarded "Prepare Dockerfile" step adds the one missing `COPY` to a copy of the maintenance Dockerfile. The pinned source stays unchanged, and the step stops if the upstream file changes.
  - Trivy is pinned to `v0.76.1`.
  - The root fix for portal-backend is in `ci/portal-backend-maintenance-dockerfile.patch`. Once the pinned commit contains it, drop the CI step.

## Isolated CI build (design)

`ci/be293-portal-images.yml` is meant to become `tx-umbrella/.github/workflows/be293-portal-images.yml` after approval.

- **Source:** checks out `ARENA2036/portal-backend` read-only at `f5badda90030531434c9445e5bb4b70382bea6eb` and verifies the SHA. portal-backend and its workflows are not changed or triggered.
- **Trigger:** `workflow_dispatch` only. `push` defaults to `false`; without it, the run only builds, checks the migrations and scans.
- **Images:** the 8 images in `images.lock.yaml`, `linux/amd64`, tag `be293-<full-sha>`. `latest` is never produced. The run fails if the tag already exists.
- **On push:** SBOM and max-mode provenance attestations; digests are written to the job summary, and then go into `images.lock.yaml`.
- **Actions:** only the SHA pins already used by portal-backend's own workflows. Permissions: `contents: read`.
- **Static review status:** actionlint and shellcheck are not installed locally, so `tools/check_package.rb` does the focused checks: expression contexts, defined inputs, matrix keys and step ids, step shape, `bash -n` on every `run`, SHA-pinned actions, permissions and triggers.
- **Fixes made in that review:**
  - Optional cross-repo read token.
  - Attestations disabled for the build-only (`load`) path.
  - The tag-collision check accepts only an explicit not-found.
  - Guard against an empty or mismatched registry host (otherwise the login defaults to Docker Hub).
  - Exact migrations assembly path.
- **Repository facts** (public GitHub API, unauthenticated, 2026-11-04):
  - `ARENA2036/tx-umbrella` is public, with default branch `develop` and Actions enabled (12 active workflows).
  - `ARENA2036/portal-backend` is public, and commit `f5badda90…` exists there.
  - So `BE293_SOURCE_READ_TOKEN` is **not needed**.
  - The GitHub MCP token cannot read ARENA2036: the org rejects fine-grained tokens with a lifetime over 366 days.
- **Activation hazard:** `install-edc.yaml` and `install-portal.yaml` in tx-umbrella run on **every push to `develop`**. Without inputs they stop at "Not a valid environment" before any kubectl or Helm call, but they would still start. The merge commit that adds this workflow must therefore contain `[skip ci]`.
- **`push=false` makes no external writes:**
  - The login, tag check and push steps are gated on `inputs.push`.
  - The build-only step has `push: false` and loads locally.
  - The migration check runs with `--network none`.
  - trivy has `cache: "false"`, because its default writes the repository's Actions cache.
  - The only output is the job summary.
  - `check_package.rb` enforces all of this.
- **Needs before a build-only run:** the workflow file on `develop`. See the steps below.
- **Additionally needs before a push run:**
  - Repository variables `BE293_REGISTRY` (registry plus namespace) and `BE293_REGISTRY_HOST`.
  - Secrets `BE293_REGISTRY_USERNAME` and `BE293_REGISTRY_PASSWORD`.

Required registry permissions (ACR terms; least privilege):

- A **repository-scoped token**, not an admin user or `AcrPush` on the whole registry.
- Its scope map covers only the 8 repositories `<namespace>/portal-{administration-service,registration-service,marketplace-app-service,services-service,notification-service,maintenance-service,processes-worker,migrations}`, with `content/read`, `content/write` and `metadata/read`.
- No `content/delete` and no `metadata/write`, so the CI token can neither untag nor delete images.
- Recommended: after each push, the registry owner locks the tag (`write-enabled false`), so `be293-*` tags stay immutable.
- Alpha needs a separate **pull-only** token (`content/read`, `metadata/read`) on the same 8 repositories, for the `be293-portal-registry-pull` Secret.

## Cross-namespace addressing

| Target | Address used | NetworkPolicy (pod port) |
|---|---|---|
| IdentityHub identity API | `http://<instance>.release26-09.svc.cluster.local:8082/api/identity` | 8082 to `<instance>` (01 or 02, owner choice) |
| IssuerService admin API | `http://issuer-service.release26-09.svc.cluster.local:8086/api/admin` | 8086 |
| BDRS management API | `http://bdrs-server.release26-09.svc.cluster.local:8081` | 8081 |
| SD-Factory | `http://sdfactory.release26-09.svc.cluster.local` (Service 80) | 8080 |
| Keycloak (central and shared) | public issuer URLs only | via shared ingress `188.34.116.149:443` and the ingress-controller pods |
| BPDM gate and pool | public host only. The chart passes one `bpdm.*` value to both browser and backend | via shared ingress |

Paths are the chart defaults of the deployed chart versions; the owners must confirm them.

## Credentials: reuse vs. new

No new Keycloak object is needed if the owner authorizes reuse of the standard seeded service accounts:

| Use | Client / key | Reuse option | Needs |
|---|---|---|---|
| Portal provisioning (CX-Central) | `sa-cl1-reg-2` | existing secret | owner hands it over, or issues a dedicated client |
| Shared IDP provisioning (master) | `sa-cl1-reg-1` | existing secret | same |
| BPDM gate | `sa-cl7-cx-5` | existing secret | same |
| SD-Factory | `sa-cl8-cx-1` | existing secret | same |
| IdentityHub identity API (provisioner/admin role) | IdentityHub super-user key | existing key | owner decision: full-admin key reuse or a dedicated key |
| IssuerService admin API | IssuerService key | existing key | same |
| BDRS management API | single management key | existing key | owner hands it over |
| Login (`Cl2-CX-Portal`, `Cl1-CX-Registration`) | public clients, no secret | existing clients | **a redirect URI and web origin for the new Portal host must be added, which is a Keycloak write** |

Reusing secrets shared with the old Portal means a rotation affects both Portals.

Unused integrations (custodian, DIM, issuer component, clearinghouse, offer provider) point to `*.disabled.invalid` and keep chart-random values. The 7 Portal encryption keys (64 hex characters each) are generated fresh for `be293`.

## Open items, by owner

- **Saud / Keycloak:**
  - Add the redirect URI and web origin for the new host to `Cl2-CX-Portal` and `Cl1-CX-Registration`.
  - Authorize reuse of `sa-cl1-reg-2`, `sa-cl1-reg-1`, `sa-cl7-cx-5` and `sa-cl8-cx-1`, or issue dedicated clients.
  - Confirm these clients exist on Alpha with the seeded roles (not readable from here).
- **Saud / IdentityHub and IssuerService:**
  - Choose `IDENTITYHUB_INSTANCE` (01 or 02) and its public host.
  - Provide the API keys.
  - Provide `ISSUER_DID`, `ISSUER_PARTICIPANT_ID`, and the BPN and Membership credential definition IDs.
  - Confirm `/api/identity` and `/api/admin`.
- **Saud / BDRS:** the management API key.
- **Platform:**
  - The new Portal and Portal-backend hosts, with DNS and TLS.
  - The ingress-controller namespace and its HTTPS container port.
  - Allow `be293` → `release26-09` in their NetworkPolicies, if needed.
  - BPDM and Semantics public hosts, and the BPDM API paths.
  - SMTP host, port, user and sender, plus the SMTP CIDR.
  - The universal resolver URL and its CIDR.
- **Dev / CI:**
  - An approved registry for Alpha.
  - Workflow targets for the 7 non-administration images. Avoid moving `latest` from a feature branch.
  - A build that records base-image digests, SBOM and provenance.
  - The 8 digests.
- **Us:** generate the 64-hex encryption keys; pre-create the adopted Secrets with Helm metadata.

## Next deployment steps (each needs explicit approval)

1. Build the 8 images: CI (`workflow_dispatch` after the workflow targets are fixed), or `tools/build-images.sh --execute` where Docker and NuGet are reachable. Then push by digest to the approved registry.
2. Fill the placeholders, then run `render.sh release` until exit 0.
3. In `be293` only: apply the NetworkPolicies, then create the Secrets (`secrets-contract.yaml`, with Helm adoption metadata for the adopted ones).
4. `helm install be293-portal <chart> -n be293 -f values-be293-portal.yaml --kubeconfig "$HOME/.kube/alpha.yaml" --kube-context alpha --wait --timeout 20m`. The only hooks are the two migration Jobs, targeting `be293-portal-postgresql`.
5. Enable Ingress after DNS and TLS exist, then run the login test. Onboarding tests write to shared services, so each one needs owner approval.

## Known chart behaviours handled here

- `postgresql.auth.externalSecretManaged=true` still renders an empty Secret, so the database credentials are chart-generated instead: fresh, and preserved through `lookup`.
- The `keycloak`, `interfaces` and `mailing` Secrets are always rendered by the chart. Shared-service values must be pre-created with Helm adoption metadata, otherwise the chart uses random, non-functional values.
- Job and CronJob pod templates have no labels, so in-namespace NetworkPolicy rules select all pods in `be293`.
- Chart choice: the vendored BE-293 chart. The root-branch patch differs: it fails on 2 of 4 hunks, lacks connector provisioning, and forces `https://` for the admin APIs.
