# BE-293 Alpha: onboarding stabilization report (2026-11-05 to 2026-11-08)

Scope: the BE-293 Portal release `be293-portal` in namespace `be293` on STACKIT Alpha (context `alpha`). Shared
`release26-09`, DEV and other namespaces were not changed. No Secrets, PVCs or database rows were changed by any
tool in this work. Live steps were run by the operator after explicit approval; everything else was prepared and
verified offline.

Reference application: `c5182556-2376-4afd-9131-15423e8e5e3e`, BPN `BPNL000000000342`,
DID `did:web:identity-hub-01.test.tractus-x.com:BPNL000000000342`.

## Outcome

| Area | State |
|---|---|
| BPN creation (BPDM 7.5.0, `/v6`) | Working for the reference application (BPN PUSH and PULL done) |
| DID validation | Working: self-hosted resolver + backend retrigger fix + one manual API retrigger |
| Administration service | Runs backend `274096a9` (digest `aff600f9…`); the other seven images unchanged (`ad459ee7`) |
| Portal UI retrigger | Fix prepared and tested (frontend patch), not deployed |
| BPNL credential | Stuck by a backend defect (see 5); fix prepared (worker patch), live state not changed |
| Helm release | Revision 1 still `failed`; drift analysed, baseline upgrade prepared, not run |
| Second application `e6d0e7f3…` | Not started (duplicate `EU_VAT_ID`) |

## 1. BPDM 7.5.0 compatibility

- Cause of the BPN creation 404: the Gate/Pool base addresses lacked `/v6`. `/v6` is the only BPDM 7.5.0 API
  version compatible with the pinned backend (v7 moved sharing-state and replaced cx-memberships).
- `tools/bpdm_openapi.rb` checks the live OpenAPI document: every backend call and the request/response fields it
  uses. Its schema resolver follows `$ref`, `allOf`, `oneOf`/`anyOf` and drops nullable alternatives
  (fixes a false positive on `PhysicalPostalAddressDto.street`), and stays fail-closed for missing fields.
- `tools/bpdm-endpoint-be293.sh`: plan / `--execute` / `--verify` / `--bpn-status` (read-only SQL).
- Known backend defect, not fixed: `SET_CX_MEMBERSHIP_IN_BPDM` sends `isArenaXMember`, upstream expects
  `isCatenaXMember` (activation step, not BPN creation).

## 2. DID validation: diagnosis

1. The worker used `https://universal-resolver.disabled.invalid/` (fail-closed placeholder, blocker R1).
2. After pointing it at `dev.uniresolver.io`, the default-deny egress policy blocked the call.
3. With egress open, the public resolver answered HTTP 403: free Godiddy plan, 10 requests per 1800 s.

Decision: self-host a did:web resolver in `be293`.

## 3. Self-hosted did:web resolver

`did-resolver-be293.alpha.yaml` (not part of the Helm release):

- **driver** `uport/uni-resolver-driver-did-uport:5.0.8` (the driver the DIF Universal Resolver uses for did:web),
  single-platform manifest `sha256:917f4d1a…`, linux/amd64 verified from the image config.
- **gateway** `nginxinc/nginx-unprivileged:1.28.0-alpine`, index `sha256:c97ff0bf…`. Required: the Portal sends the
  DID percent-encoded and the driver only matches the raw URL. The gateway also limits the API to GET for
  `did:web` under `*.test.tractus-x.com`.
- ClusterIP Service `be293-did-resolver:8080`, ingress policy (TCP 8080 from be293 pods), egress policy
  (cluster DNS and HTTPS to the shared ingress only). Non-root, read-only root FS, no capabilities, no SA token.
- Gates DR1–DR11 (`tools/validate_did_resolver.rb`), part of `tools/render-release.sh`.
- `tools/did-resolver-be293.sh`: `--pin` (accepts indexes and single-platform manifests, verifies digest
  integrity at every level and linux/amd64 from the config blob), dry run, `--execute` (create, in-cluster probe
  with the Portal's exact request form, then patch only the two worker resolver variables), `--verify`, `--diff`.
- Worker variables `APPLICATIONCHECKLIST__{IDENTITYHUB,DIM}__UNIVERSALRESOLVERADDRESS` are persisted in
  `values-be293-portal.alpha-release.yaml` (gate DR9).

## 4. Backend defect: DID validation retrigger

- `RETRIGGER_VALIDATE_DID_DOCUMENT` set `IDENTITY_WALLET` to `TO_DO`; `VALIDATE_DID_DOCUMENT` only runs while
  it is `IN_PROGRESS`. A retrigger therefore failed the step at once with no further retrigger.
  Upstream `eclipse-tractusx/portal-backend` main has the same mapping.
- Fix: map to `IN_PROGRESS` (`ci/portal-backend-retrigger-validate-did.patch`). Commit `274096a9` on
  `fix/BE-293-retrigger-validate-did-in-progress`, parent `ad459ee7` (the deployed commit).
- Tests: two regression tests reproduce the live failure before the fix. Native results:
  ApplicationChecklist.Library 37, BpnDidResolver.Library 22, ApplicationChecklist.Executor 49,
  Administration.Service 788 unit + 4 Docker integration, all passed.
- Only `portal-administration-service` reads the mapping. The isolated workflow (tx-umbrella branch
  `fix/be293-retrigger-images`, only `SOURCE_COMMIT` changed) built all eight images; build-only run
  42370885874 succeeded 8/8. The admin image was then published and deployed alone.

## 5. Portal UI retrigger and BPNL 409

Frontend (`ci/portal-frontend-checklist-retrigger.patch`, on upstream `v2.6.0` `8d0adbdd`):

- Missing endpoint mappings (`RETRIGGER_VALIDATE_DID_DOCUMENT`, `RETRIGGER_CREATE_IDENTITY_HUB_WALLET`) made the
  UI post to `…/undefined`. The call now only goes to known endpoints.
- Retrigger offered only for `FAILED` entries; one explicit action per step (never several at once); duplicate
  click guard; loading always resets; 409 and other errors shown, never retried; checklist refreshed.
- 46 Jest tests (26 new), `tsc`, ESLint (`--max-warnings 0`) and `yarn build` pass; new tests fail on the old code.

BPNL credential 409 (backend, not fixed): when the IdentityHub reports the credential request as failed or the
wait deadline passes, `IdentityHubCredentialAwaitBusinessLogic` fails the step and schedules
`RETRIGGER_REQUEST_BPN_CREDENTIAL` but leaves `BPNL_CREDENTIAL` `IN_PROGRESS`. The backend then correctly rejects
the retrigger (requires `FAILED`). The await step should also set the entry `FAILED`.

Fixed (2026-11-08, not deployed): `ci/portal-backend-identityhub-await-checklist-failed.patch` on base `274096a9`
(branch `fix/BE-293-identityhub-await-checklist-failed`, created by `ci/archive/prepare-portal-backend-await-fix.sh`). Both
terminal branches set the entry `FAILED` with a non-sensitive comment; processes-worker image only. 16 new test cases
fail on the old code. The reference application needs the read-only check `tools/credential-status-be293.sh` and,
if it reports the mismatch, the guarded one-time reconciliation in runbook section C (separate approval).

## 6. Release package and Helm

- `images.lock.yaml` / `values-be293-portal.yaml`: admin pinned at `274096a9@sha256:aff600f9…`, the other seven at
  their live `ad459ee7` digests; the published but undeployed `274096a9` builds are under
  `publishedNotDeployed`, which gate G4 never renders. `tools/record_portal_images.rb` edits only `rebuilt`.
- `tools/helm-diff-be293.sh`: read-only diff in any release state. `tools/compare_release_live.rb` normalizes
  API defaults (Service ports, probe/volume/quantity defaults, Helm bookkeeping annotations), compares probes,
  security contexts, resources, ServiceAccount, selectors, volumes and mounts, and reports field ownership:
  a change to a field owned by a manager other than Helm is an SSA conflict (FAIL).
- Drift found by the first diff (18 drifted, 11 same): Service ports and Ingress annotations were comparison
  artifacts; environment drift is BPDM `/v6` (intended fix), resolver placeholders (harmless) and the
  the shared-realm SMTP target. Decision 2026-11-08: keep the live Office 365 shared-realm configuration;
  the smtp4dev overlay no longer overrides it (gate S9 pins it), so that drift is gone. No Secret would change.
- Baseline: revision 1 is the only revision and is `failed`; `tools/recover-be293.sh --execute`
  (`helm upgrade --no-hooks`) creates revision 2. Not run.

## Verification summary

| Suite | Result |
|---|---|
| Release package (`ruby tests/test_*.rb`) | 193 runs, 0 failures |
| Offline release gates (`tools/render-release.sh`) | PACKAGE, RESULT, INGRESS, RETENTION, RETENTION D8, SMTP4DEV, DID RESOLVER: PASS |
| Backend (native, operator machine) | 900 tests passed incl. 4 Docker integration |
| Frontend | 46/46 Jest, tsc, ESLint, production build |
| CI build-only run 42370885874 | 8/8 images, push=false |

## Files added or changed in the release package

`did-resolver-be293.alpha.yaml`, `values-be293-portal.alpha-release.yaml`, `values-be293-portal.yaml`,
`images.lock.yaml`, `ci/be293-portal-images.yml`, `ci/portal-backend-retrigger-validate-did.patch`,
`ci/archive/prepare-portal-backend-retrigger-fix.sh`, `ci/archive/tx-umbrella-be293-portal-images-274096a9.patch`,
`ci/archive/run-be293-build-only.sh`, `ci/portal-frontend-checklist-retrigger.patch`,
`tools/validate_did_resolver.rb`, `tools/did-resolver-be293.sh`, `tools/record_portal_images.rb`,
`tools/compare_release_live.rb`, `tools/helm-diff-be293.sh`, `tools/render-release.sh`, `tools/bpdm_openapi.rb`,
`tools/bpdm-endpoint-be293.sh`, `README-ALPHA-RELEASE.md`, tests under `tests/`.

`.evidence/` holds full workload specs from Alpha: keep it out of Git.

Next steps: [BE293-RUNBOOK-NEXT-STEPS.md](BE293-RUNBOOK-NEXT-STEPS.md).
