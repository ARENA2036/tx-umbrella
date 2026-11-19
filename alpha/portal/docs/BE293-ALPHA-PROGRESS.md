# BE-293 Portal on STACKIT Alpha: progress report

Status date: 2026-11-13. Live state last verified on 2026-11-10 (Helm revision 5, `SMOKE PASS`).
Nothing on Alpha was changed after that date.

| Item | Value |
|---|---|
| Cluster / context | STACKIT Alpha, context `alpha`, kubeconfig `~/.kube/alpha.yaml` |
| Namespace | `be293` |
| Helm release | `be293-portal`, chart `portal-2.6.0` (app version 2.6.0) |
| Public hosts | `https://portal-be293.test.tractus-x.com` (frontend, `/registration`), backend Ingress `be293-portal-backend` |
| Release package | `$REL` |
| Package in Git | `ARENA2036/tx-umbrella`, branch `feat/BE-293-alpha-release-package`, commit `334ef7d` (pushed 2026-11-10) |
| Out of scope (never changed) | namespace `release26-09` (shared IssuerService/IdentityHub), DEV, other namespaces, Secrets, PVCs, database rows |

Related documents: [folder guide](BE293-FOLDER-GUIDE.md), [runbook](BE293-RUNBOOK-NEXT-STEPS.md),
[session report 2026-11-05 to 11-08](BE293-SESSION-REPORT-2026-11.md), [release README](../README-ALPHA-RELEASE.md).

---

## 1. Summary

| Area | State |
|---|---|
| Helm release | **Revision 5 `deployed`** (2026-11-09). Revision 1 (failed install) is superseded. |
| All workloads | Ready; smoke test PASS after every upgrade (revisions 2-5). |
| BPN creation (BPDM 7.5.0, `/v6`) | **Working.** |
| DID validation | **Working** (self-hosted did:web resolver + backend retrigger fix). |
| Checklist await defect (409 on retrigger) | **Fixed and deployed** (worker `8ca2c1ecc`, in revision 3 onwards). |
| Activation membership via IdentityHub | **Fixed and deployed** (worker `2cd5dd8a4`, revision 4 onwards). |
| BPDM `isCatenaXMember` field | **Fixed and deployed** (worker `e2451f876`, revision 5). |
| BPN credential for the new test application | **Blocked on the issuer side** (`release26-09`, not ours). Design proposal ready for Saud. |
| Membership credential | Open: requires an organisational decision (who is an approved member). |
| Portal UI retrigger button | Fix prepared and tested (frontend patch). **Not deployed.** |
| Release package | Committed and pushed to Git; 214 tool tests and 7 offline gates pass. |

---

## 2. Timeline

| Date | What happened |
|---|---|
| 2026-11-02 | Sanitized Umbrella 3.17.0 DEV baseline and deployment handoff added to the integration line. |
| 2026-11-04 | Isolated image workflow `be293-portal-images.yml` merged in tx-umbrella (PR #239). First run 41849663453: 7/8 images built; maintenance-service Dockerfile and Trivy version fixed afterwards. |
| 2026-11-05 | Helm install `be293-portal` revision 1 ends `failed` (five Deployments exceeded the progress deadline). Data was kept (retention post-renderer). |
| 2026-11-05 to 11-07 | BPN creation fixed (BPDM `/v6`). DID validation diagnosed: placeholder resolver, egress block, public resolver rate limit (HTTP 403). Self-hosted did:web resolver deployed in `be293`. |
| 2026-11-07 | Backend fix `274096a96` (DID retrigger sets `IDENTITY_WALLET` to `IN_PROGRESS`). Build-only run 42370885874 built 8/8 images; only the administration-service image was published and rolled out. Reference application passed DID validation after one manual retrigger. |
| 2026-11-08 | Drift analysis with field ownership; `expected-drift.alpha.yaml` reviewed. Shared-realm SMTP kept on Office 365 (decision). **Revision 2** created by `tools/recover-be293.sh --execute` (19:46): first successful Helm baseline. |
| 2026-11-08 | Await defect fixed in backend (`8ca2c1ecc`). |
| 2026-11-09 09:38 | **Revision 3**: worker `8ca2c1ecc` (await sets entry `FAILED`). |
| 2026-11-09 | Activation fix `2cd5dd8a4`: no Custodian call on the IdentityHub path; activation requires both credentials issued. Image run 42596731420. |
| 2026-11-09 11:04 | **Revision 4**: worker `2cd5dd8a4`. |
| 2026-11-09 | Live BPDM schema check confirms `isArenaXMember` vs `isCatenaXMember` mismatch. Fix `e2451f876`, image run 42600052811. |
| 2026-11-09 ~11:28 | **Revision 5**: worker `e2451f876`. Smoke PASS. |
| 2026-11-09 to 11-10 | New E2E application `d6b4f796` registered. BPN credential fails at the IssuerService (HTTP 500). Read-only root-cause analysis of the issuer; view-based design prepared. |
| 2026-11-10 | Folder clean-up, folder guide, release package committed and pushed (`334ef7d`). AI attribution removed from unpublished work. |

---

## 3. What is deployed now (revision 5)

Source of truth: `images.lock.yaml` and `values-be293-portal.yaml` (registry `harbor-hub-shared.arena.3ascloud.de/be293`).

| Image | Tag (source commit) | Digest | Since |
|---|---|---|---|
| portal-administration-service | `be293-274096a965c1…` | `sha256:aff600f9…` | 2026-11-07 |
| portal-processes-worker | `be293-e2451f87628c…` | `sha256:0857101e…` | revision 5 |
| portal-registration-service | `be293-ad459ee711ec…` | `sha256:a83cf141…` | install |
| portal-marketplace-app-service | `be293-ad459ee711ec…` | `sha256:2d5c3f6b…` | install |
| portal-services-service | `be293-ad459ee711ec…` | `sha256:2abb07a9…` | install |
| portal-notification-service | `be293-ad459ee711ec…` | `sha256:982e7775…` | install |
| portal-maintenance-service | `be293-ad459ee711ec…` | `sha256:08ee4b36…` | install |
| portal-migrations | `be293-ad459ee711ec…` | `sha256:c10f64ca…` | install |
| portal-frontend (upstream) | `v2.6.0` | `sha256:d0fe6dd2…` | install |
| portal-frontend-registration (upstream) | `v2.2.2` | `sha256:36bf200b…` | install |
| portal-assets (upstream) | `v2.6.0` | `sha256:27cf6ef9…` | install |

Published but deliberately not deployed (listed under `publishedNotDeployed`): the 274096a96 builds of the other
seven backend images, and the superseded workers `8ca2c1ecc` (`sha256:e2ab28e1…`) and `2cd5dd8a4` (`sha256:421bf1fd…`).

Never deploy (`forbidden` in the lock): `be293-images`, `claimfix`, `cp-933aeeb25` (personal DEV registry or unknown source).

Not part of the Helm release (own manifests and scripts):

| Component | File | Purpose |
|---|---|---|
| did:web resolver | `did-resolver-be293.alpha.yaml` | uport driver 5.0.8 + nginx gateway; GET only, `did:web` under `*.test.tractus-x.com` |
| smtp4dev | `smtp4dev-be293.alpha.yaml` | Test mail sink for Portal mail of the processes-worker |
| NetworkPolicies | `networkpolicies-be293-portal*.yaml` | Default-deny with explicit egress (DNS, resolver, SMTP, shared ingress) |

---

## 4. Helm revision history

| Rev | Date | Change | How | Result |
|---|---|---|---|---|
| 1 | 2026-11-05 | First install | `tools/install-be293.sh --execute` | `failed` (progress deadline), now superseded |
| 2 | 2026-11-08 | Recovery baseline: BPDM `/v6`, BPNAccess `/v6`, in-cluster DID resolver address, frontend BPDM URLs | `tools/recover-be293.sh --execute` (`helm upgrade --no-hooks`) | Upgrade complete, smoke PASS |
| 3 | 2026-11-09 | Worker `8ca2c1ecc` only | `tools/upgrade-be293.sh --execute` | Upgrade complete, smoke PASS |
| 4 | 2026-11-09 | Worker `2cd5dd8a4` only | `tools/upgrade-be293.sh --execute` | Upgrade complete, smoke PASS |
| 5 | 2026-11-09 | Worker `e2451f876` only | `tools/upgrade-be293.sh --execute` | Upgrade complete, smoke PASS |

Each upgrade: offline gates, read-only diff, expected-drift check (only the worker CronJob image and the Rancher
`field.cattle.io/publicEndpoints` annotation on two Ingresses), typed confirmation, snapshot in
`.evidence/pre-revision-N-<time>/` (live objects without Secrets, ReplicaSets, Helm history, images before/after),
one `helm upgrade --no-hooks` with server-side apply, then verification that only the intended image changed.

Never: `helm rollback` to revision 1, `helm uninstall`, `--force-conflicts`.

---

## 5. Problems solved, one by one

### 5.1 BPN creation returned 404
- **Cause:** BPDM Gate/Pool base addresses had no `/v6`. BPDM 7.5.0 v7 changed sharing-state and cx-memberships, so `/v6` is the only compatible version for the pinned backend.
- **Fix:** `/v6` on Gate, Pool and BPNAccess for administration, registration and frontend (values; revision 2).
- **Tool:** `tools/bpdm_openapi.rb` checks the live OpenAPI against every field the backend uses (fail-closed).
- **Result:** BPN PUSH and PULL done for the reference application.

### 5.2 DID validation failed
- **Causes, in order:** placeholder resolver `https://universal-resolver.disabled.invalid/` (fail-closed); egress blocked by default-deny; public resolver `dev.uniresolver.io` answered HTTP 403 (free plan, 10 requests per 30 min).
- **Fix:** self-hosted did:web resolver in `be293` (`tools/did-resolver-be293.sh`, gates DR1-DR11). The nginx gateway decodes the percent-encoded DID the Portal sends.
- **Hardening:** non-root, read-only root FS, no capabilities, no ServiceAccount token, own ingress/egress policies.

### 5.3 DID retrigger failed immediately (backend defect)
- **Cause:** `RETRIGGER_VALIDATE_DID_DOCUMENT` set `IDENTITY_WALLET` to `TO_DO`; validation only runs while `IN_PROGRESS`. Same in upstream main.
- **Fix:** commit `274096a96` on `fix/BE-293-retrigger-validate-did-in-progress` (parent `ad459ee7`). Only administration-service reads this mapping, so only that image was rolled out.
- **Tests:** two regression tests; 900 backend tests passed natively, including 4 Docker integration tests.

### 5.4 Retrigger of BPN/Membership credential answered 409 (backend defect)
- **Cause:** `IdentityHubCredentialAwaitBusinessLogic` failed the await step and scheduled the retrigger, but left `BPNL_CREDENTIAL` / `MEMBERSHIP_CREDENTIAL` `IN_PROGRESS`. The retrigger requires `FAILED`, so it was rejected.
- **Fix:** commit `8ca2c1ecc` on `fix/BE-293-identityhub-await-checklist-failed`: both terminal paths (holder ERROR, deadline) set the entry `FAILED` with a non-sensitive comment, in the same transaction. 16 new test cases.
- **Deployed:** revision 3.
- **Note:** applications already stuck before the fix need the guarded one-time reconciliation in runbook section C (separate approval). `tools/credential-status-be293.sh` gives the verdict.

### 5.5 Activation used the Custodian path and could skip credentials (backend defect)
- **Cause:** with `walletProvider: IdentityHub`, `ApplicationActivationService.SetMembership` still went through the Custodian logic.
- **Fix:** commit `2cd5dd8a4` on `fix/BE-293-identityhub-activation-membership`: no Custodian call on the IdentityHub path; activation refuses to continue unless both the BPN and the Membership credential were issued (`EnsureIdentityHubCredentialsIssued`, based on `GetChecklistProcessStepHistory`). Activation never silently bypasses a missing mandatory credential. 8 tests.
- **Deployed:** revision 4.

### 5.6 BPDM rejected the membership update (backend defect)
- **Cause:** commit `43767079b` ("ARENA branding") renamed the field to `isArenaXMember`; BPDM 7.5.0 `CxMembershipDtoV6` expects `isCatenaXMember`. Confirmed live with `curl -s https://business-partners.test.tractus-x.com/pool/docs/api-docs | ruby tools/bpdm_openapi.rb --api pool`.
- **Fix:** commit `e2451f876` on `fix/BE-293-bpdm-cx-membership-field`: `[JsonPropertyName("isCatenaXMember")]`; test asserts the exact body `{"memberships":[{"bpnL":"123","isCatenaXMember":true}]}`.
- **Deployed:** revision 5.

### 5.7 Helm release stuck at a failed install
- **Fix:** recovery upgrade to revision 2 with reviewed expected drift (5 Deployments, 2 Ingress annotations), no Secret change, PVC protected.
- **Decision 2026-11-08:** shared-realm SMTP stays on the live Office 365 setup (gate S9); worker Portal mail goes to smtp4dev.

---

## 6. Applications under test

| Application | BPN | Status |
|---|---|---|
| `c5182556-2376-4afd-9131-15423e8e5e3e` (legacy reference) | `BPNL000000000342` | BPN and DID done. Its credentials were not issued through the current IdentityHub flow, so the activation check from 5.5 refuses to activate it. This is intended behaviour, not a defect. Use it as a reference only. |
| `d6b4f796-a248-4dc6-86c5-de44486df08f` (new E2E) | `BPNL00000000052O` | DID `did:web:identity-hub-01.test.tractus-x.com:BPNL00000000052O`. Earlier checklist steps done; **BPN credential fails at the IssuerService** (see 7). |
| `e6d0e7f3-d8ac-4310-bd84-0a94bf9c657c` | — | Not continued: BPN PULL failed with duplicate `EU_VAT_ID_DE = DE123456789` (test data collision in shared BPDM). |

---

## 7. Open blocker: BPN credential at the IssuerService (`release26-09`)

This is outside `be293` and must be changed by the issuer owner (Saud). We made no change there.

**Root cause (read-only analysis of EDC IdentityHub/IssuerService v0.17.0, Tractus-X IssuerService 0.4.1):**
- The `BpnCredential` definition uses a database attestation: `SELECT * FROM <table> WHERE holder_id = ?` with the holder ID (= BPN).
- There is no row for `BPNL00000000052O`, so the source returns `null`; `AttestationPipelineImpl.putAll(null)` throws a NullPointerException and the issuer answers HTTP 500.
- `credential_definitions.credential_type` is `UNIQUE` (verified live), so a second `BpnCredential` definition is not possible.

**Proposed permanent fix (view-based attestation, for the `release26-09` seed/bootstrap):**
1. View `public.bpn_attestation_claims`: existing custom rows unchanged (`lookup_id = holder_id`), plus generated rows from `holders` only when `participant_context_id = 'issuer'`, not anonymous, BPN matches the BPNL pattern, the DID ends with that BPN, no custom row exists, and the DID is unique. `member_of` stays `NULL`.
2. New attestation `bpn-holders-view-attestation`: data source `customattestations`, table `bpn_attestation_claims`, `idColumn` `lookup_id`, `required: true`.
3. `PUT` the `BpnCredential` definition changing only `attestations`.
4. Rollback: the same steps in reverse order.

All read-only pre-checks passed. After Saud applies it: one approved retrigger of `d6b4f796`, then watch with
`tools/credential-status-be293.sh d6b4f796-a248-4dc6-86c5-de44486df08f`.

**Membership credential:** separate decision. A registered holder must not automatically count as an approved
Catena-X member, so the view does not grant membership.

---

## 8. Source code and branches

| Repository | Branch | Commit | Content | On GitHub |
|---|---|---|---|---|
| `ARENA2036/portal-backend` | `fix/BE-293-retrigger-validate-did-in-progress` | `274096a96` | DID retrigger fix | yes |
| `ARENA2036/portal-backend` | `fix/BE-293-identityhub-await-checklist-failed` | `8ca2c1ecc` | await sets entry FAILED | yes |
| `ARENA2036/portal-backend` | `fix/BE-293-identityhub-activation-membership` | `2cd5dd8a4` | activation via IdentityHub | yes |
| `ARENA2036/portal-backend` | `fix/BE-293-bpdm-cx-membership-field` | `e2451f876` | `isCatenaXMember`; contains all fixes above | yes |
| `ARENA2036/tx-umbrella` | `fix/be293-retrigger-images` | `c83dc66` | image workflow for 274096a96 | yes |
| `ARENA2036/tx-umbrella` | `fix/be293-await-worker-image` | `fa30933` | worker-only image workflow (`SOURCE_COMMIT` e2451f876) | yes |
| `ARENA2036/tx-umbrella` | `feat/BE-293-alpha-release-package` | `334ef7d` | this release package | yes |

The backend branches are stacked (each builds on the previous one). None is merged into `develop` yet.
Agreed merge rule: squash merge with a reviewed message (no AI attribution).

Image builds (tx-umbrella, isolated workflow, immutable `be293-<sha>` tags):

| Run | Source | Result |
|---|---|---|
| 41849663453 | f5badda90 | 7/8, push=false (first run) |
| 42370885874 | 274096a96 | 8/8, push=false; admin image then published |
| 42581538733 | 8ca2c1ecc | worker published |
| 42596731420 | 2cd5dd8a4 | worker published |
| 42600052811 | e2451f876 | worker published (`sha256:0857101e…`) |

---

## 9. Release package and safety tooling

Everything is in the package (see the [folder guide](BE293-FOLDER-GUIDE.md)):
- **Configuration:** values plus three overlays (release, retention, smtp4dev), `images.lock.yaml`, `expected-drift.alpha.yaml`, `secrets-contract.yaml` (key names only).
- **Guarded change scripts:** dry run by default, `--execute` plus typed confirmation, fixed kubeconfig/context/namespace, snapshot before every change.
- **Read-only checks:** `smoke-be293.sh`, `helm-diff-be293.sh`, `credential-status-be293.sh`, `bpdm-endpoint-be293.sh`, `diagnose-invitation-be293.sh`.
- **Offline gates** (`tools/render-release.sh`): PACKAGE, RESULT, INGRESS, RETENTION, RETENTION D8, SMTP4DEV, DID RESOLVER.
- **Data protection:** `helm-plugins/be293-retention` keeps Secrets and the PostgreSQL PVC (`keep`, Retain) and suspends the maintenance CronJob.
- **Bruno collection** `bruno/issuer-service-readonly/`: read-only IssuerService admin calls and Portal checklist calls with operator login (PKCE); tokens stay in Bruno, never in files.
- `.evidence/` (snapshots of revisions 2-5, build logs) and `.claude/` are git-ignored.

---

## 10. Verification

| Check | Result |
|---|---|
| Release package tests (`for t in tests/test_*.rb; do ruby "$t"; done`) | 214 runs, 0 failures (revision 5) |
| Offline gates | 7/7 PASS |
| Backend, DID fix | 900 tests incl. 4 Docker integration, all passed |
| Backend, await fix | 16 new test cases; fail on the old code |
| Backend, activation fix | 8 tests |
| Backend, BPDM field | request body test with `isCatenaXMember` |
| Frontend retrigger patch | 46/46 Jest, `tsc`, ESLint `--max-warnings 0`, production build |
| Smoke test on Alpha | PASS after revisions 2, 3, 4, 5 |

Backend tests from 8ca2c1ecc onwards were run by the operator on the local machine.

---

## 11. Next steps

| # | Step | Owner | Approval |
|---|---|---|---|
| 1 | Send the issuer view proposal (section 7) to Saud; he applies it in `release26-09` and its seed | Saud | his team |
| 2 | One retrigger of the BPN credential for `d6b4f796`, then watch C3/C4 | Operator | yes |
| 3 | Decide how Membership credentials are attested (approved members only) | Product / issuer owner | — |
| 4 | Complete the onboarding of `d6b4f796` up to activation | Operator | per step |
| 5 | PRs for the backend branches and the workflow branch into `develop`, squash merge | Payam | review |
| 6 | PR for the release package branch | Payam | review |
| 7 | Deploy the Portal UI retrigger fix (runbook section B) | Operator | yes |
| 8 | Decide on the leftover local folders with unpushed DEV work (clean-baseline, dev-recovery, 013-acceptance, dtr-tls, 0.13-integration) | Payam | — |
| 9 | Restructure the package into the target layout (`alpha/be293-portal/{config,manifests,tools,…}`) | Payam | yes |

---

## 12. Risks and open points

- **Issuer dependency:** BPN issuance for new holders depends on a change in `release26-09`. Until then every new application stops at the BPN credential.
- **Membership policy is undecided:** activation correctly blocks without a Membership credential.
- **Single-commit drift:** six backend images still run `ad459ee7`, admin runs `274096a96`, worker runs `e2451f876`. All are from the same line, but a full rebuild from one commit is still open.
- **tx-umbrella `develop`** still builds `f5badda90` in its workflow; the deployed images were built from feature branches.
- **Real SMTP (M1)** is not set up; Portal mail from the worker goes to smtp4dev.
- **History:** published commits `274096a96` and `c83dc66` contain a `Co-Authored-By` trailer. Not rewritten, because Alpha image tags reference them; removed at squash merge.
- **Not re-verified on 2026-11-13:** live cluster state (this report relies on the 2026-11-10 verification).
