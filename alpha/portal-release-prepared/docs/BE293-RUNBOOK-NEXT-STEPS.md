# BE-293 Alpha: runbook for the remaining steps

Run from `~/Projects/ARENA2036/BE293_ALPHA/tx-umbrella/alpha/portal-release-prepared` on the operator machine
(the Alpha kubeconfig is `~/.kube/alpha.yaml`, context `alpha`, namespace `be293`).
Steps marked **approval** change something; take them one at a time, after explicit approval.
Never touch `release26-09`, DEV, Secrets, PVCs or the database.

Background: [BE293-SESSION-REPORT-2026-11.md](BE293-SESSION-REPORT-2026-11.md).

## A. Establish a successful Helm baseline

1. **Offline gates (read-only).**
   ```bash
   KUBECONFIG=/dev/null bash tools/render-release.sh | grep -E 'RESULT|^FAIL'
   ```
   Expect seven PASS lines.

2. **Read-only diff against Alpha** (uses the extended comparison with field ownership).
   ```bash
   bash tools/helm-diff-be293.sh 2>&1 | tee ~/be293-helm-diff.txt
   ```
   Go on only if all of these hold:
   - no `FAIL` line and no `CONFLICT`;
   - Services, Ingresses, Secrets and the PostgreSQL StatefulSet are `SAME`;
   - only these workloads drift, each `[owner: helm]`: administration-service (BPDM `/v6`, BPNAccess, resolver),
     marketplace-app-service and services-service (DIM resolver), registration-service
     (BPNAccess), portal (BPDM Gate/Pool URLs); processes-worker shows no drift;
   - the DID resolver reports `NO DRIFT` and is not Helm-managed.

3. **Shared-realm SMTP: decided (2026-11-08).** Kept as live (Office 365, existing Secret reference); gate S9
   enforces it. Portal mail from the processes-worker stays on smtp4dev.

4. **Dry run of the recovery (read-only).**
   ```bash
   bash tools/recover-be293.sh
   ```
   It requires "1 revision, failed", the manual migration Jobs succeeded, the PostgreSQL PVC Bound, the smtp4dev
   Service present, DNS egress, and no Secret change. Every DRIFT item must also be listed in
   `expected-drift.alpha.yaml` (reviewed 2026-11-08: 5 Deployments, Rancher annotation on 2 Ingresses); any other
   drift prints `UNEXPECTED …` and stops the script before the confirmation. Expect `EXPECTED-DRIFT OK`.

5. **Approval: create revision 2.**
   ```bash
   bash tools/recover-be293.sh --execute
   ```
   Repeats steps 0–4 (any unexpected drift stops it), asks for the typed confirmation, snapshots the live
   objects (no Secrets) and ReplicaSet revisions to `.evidence/pre-revision-2-<time>/`, then runs one
   `helm upgrade --no-hooks --wait --timeout 15m` (server-side apply, no `--force-conflicts`, no rollback or
   cleanup on failure). Expected: rolling restarts of administration (3 replicas), marketplace, services,
   registration-service and portal; processes-worker, images, Secrets, Services and Ingress specs unchanged;
   Rancher's `field.cattle.io/publicEndpoints` kept (not Helm-owned, so server-side apply leaves it).

6. **Smoke test (read-only), within 15 minutes of the upgrade.**
   ```bash
   bash tools/smoke-be293.sh               # add --with-probe for the in-pod DID resolution probe (kubectl exec)
   bash tools/helm-diff-be293.sh           # expect only the Rancher annotation lines as DRIFT
   ```
   `SMOKE PASS` requires: latest revision deployed; every Deployment and PostgreSQL ready; images equal the pins;
   BPDM `/v6`, BPNAccess and resolver values live on all five Deployments; shared-realm SMTP still
   `smtp.office365.com:587` with the Secret reference; worker mail still on smtp4dev; Rancher annotation present;
   no 502/503/504 on the public routes; no startup exceptions; resolver endpoint ready.
   Functional check (operator, UI): open the reference application's checklist; company data / partner network
   pages load BPDM data without errors in the browser console.

**Emergency recovery (there is no earlier successful revision)**
- **The upgrade fails** (`--wait` timeout or apply error): revision 2 is `failed`, nothing is deleted, objects
  stay as far as they were applied. Read-only diagnosis first (`kubectl get pods`, `describe`, `logs`).
  If a restarted Deployment does not become ready, roll back only that Deployment (approval):
  `kubectl --kubeconfig ~/.kube/alpha.yaml --context alpha -n be293 rollout undo deployment/<name>`; its previous
  ReplicaSet revision is in the snapshot's `replicasets.txt`. `recover-be293.sh` will then refuse to run again
  (history is no longer "1 failed"); a second attempt needs a reviewed change of that state check.
- **The upgrade succeeds but behaviour regresses** (smoke FAIL or user-visible error): `rollout undo` of the
  affected Deployment(s) restores their previous pod template (old env, same images) within minutes; Helm then
  records revision 2 while the Deployment runs the old template, so the next diff shows that drift until the
  values are fixed and a reviewed upgrade runs.
- **Never** `helm rollback` to revision 1 (the failed install manifest: old admin image, BPDM without `/v6`),
  never `helm uninstall` (Secrets and the PostgreSQL PVC are `keep`/Retain, but every workload would be deleted),
  never `--force-conflicts`.
- The full pre-upgrade object specs are in `.evidence/pre-revision-2-<time>/objects.yaml` for a manual, reviewed
  restore of any single object.

## B. Deploy the Portal UI retrigger fix

1. **Branch (local).** In a clone of `ARENA2036/portal-frontend`:
   ```bash
   git switch -c fix/BE-293-checklist-retrigger 8d0adbddd5a068d1f4f58c41c27859af5704f570
   git am <release-package>/ci/portal-frontend-checklist-retrigger.patch
   yarn install --frozen-lockfile && yarn test && yarn lint && yarn build
   ```
2. **Approval: push** the branch (no merge).
3. **Build-only image run** (new isolated tx-umbrella workflow modelled on `be293-portal-images.yml`):
   `yarn install --frozen-lockfile`, tests, lint, build; image from the prebuilt output with the nginx base pinned
   to `nginx-unprivileged:1.28.0-alpine@sha256:c97ff0bf…`; tag `be293-<sha>`, SBOM, provenance, Trivy,
   refuse-to-overwrite. Do not use upstream `Dockerfile.full` (plain `yarn`, floating bases).
4. **Approval: publish**, then record the digest: `frontend.portal.image` in `values-be293-portal.yaml` and a
   frontend entry in `images.lock.yaml` (gate G4 needs a small extension to accept it).
5. **Approval: deploy** only `be293-portal-portal`; verify that the DID retrigger button sends one POST to
   `…/retrigger-validate-did` and that `IN_PROGRESS` items show no retrigger.

**Rollback:** set `frontend.portal.image` back to `docker.io/tractusx/portal-frontend:v2.6.0@sha256:d0fe6dd2…`
(still recorded under `upstream` in the lock) and roll the portal Deployment.

## C. BPNL / Membership credential: await fix and one-time reconciliation

Defect: `IdentityHubCredentialAwaitBusinessLogic` failed `AWAIT_BPN_CREDENTIAL_RESPONSE` /
`AWAIT_MEMBERSHIP_CREDENTIAL_RESPONSE` (holder ERROR or wait deadline) and scheduled the retrigger, but left the
`BPNL_CREDENTIAL` / `MEMBERSHIP_CREDENTIAL` entry `IN_PROGRESS`; the retrigger requires `FAILED` and answers 409.
Fix: `ci/portal-backend-identityhub-await-checklist-failed.patch` (base `274096a9`, processes-worker only).
The fix does not repair an application that is already in that state: its await step is no longer active.

1. **Read-only state of the reference application** (no approval needed).
   ```bash
   bash tools/credential-status-be293.sh            # or: ... <application-uuid>
   ```
   C4 prints one verdict per credential. `MISMATCH: reconciliation candidate` means: latest await step `FAILED`,
   entry `IN_PROGRESS`, retrigger step `TODO`, no request/await step `TODO`, process not locked. C5 shows whether
   the worker logged `as ERROR` (holder failed) or `still … after N day(s)` (deadline). Keep the output.
2. **Branch and tests (local).** `bash ci/archive/prepare-portal-backend-await-fix.sh` creates
   `fix/BE-293-identityhub-await-checklist-failed` from `274096a9` in a new worktree, applies the patch (exactly
   4 files), publishes Processes.Worker, runs the affected test projects and commits with your git identity.
3. **Approval: push, build-only processes-worker image, record the digest** (`backend.processesworker.image`,
   `images.lock.yaml`; the published `274096a9` worker build is superseded). Add the worker image line to
   `expected-drift.alpha.yaml`, then `bash tools/helm-diff-be293.sh`: only the worker image may drift.
4. **Approval: upgrade (revision 3)**, worker image only: `bash tools/upgrade-be293.sh` (read-only dry run), then
   `bash tools/upgrade-be293.sh --execute` (typed confirmation, snapshot to `.evidence/pre-revision-3-<time>/`, one
   `helm upgrade --no-hooks`). It requires revision 2 `deployed`, the reviewed worker pin, and drift only on the worker
   CronJob image and the Rancher annotations; afterwards it verifies that only the worker image changed. Then
   `bash tools/smoke-be293.sh`.
5. **Re-check (read-only):** `bash tools/credential-status-be293.sh`. The verdict is unchanged by the deploy.
6. **Approval: one-time reconciliation, only if C4 says `MISMATCH: reconciliation candidate`.** A single
   transaction that changes one row, the `BPNL_CREDENTIAL` entry, from `IN_PROGRESS` to `FAILED` with a comment,
   and only while the exact mismatch still holds. Nothing else: no step is reset, skipped, created or completed,
   no credential is created. Run it from a reviewed script (typed confirmation, `-v ON_ERROR_STOP=1`,
   `-v app=<uuid>`), after a fresh step 5 output:
   ```sql
   BEGIN;
   SET LOCAL lock_timeout = '5s';
   -- Serialize with the worker: lock the unlocked checklist process row (expect exactly 1 row).
   SELECT p.id FROM portal.processes p
   JOIN portal.company_applications ca ON ca.checklist_process_id = p.id
   WHERE ca.id = :'app'::uuid AND (p.lock_expiry_date IS NULL OR p.lock_expiry_date <= now())
   FOR UPDATE OF p;
   UPDATE portal.application_checklist ac
   SET application_checklist_entry_status_id = (SELECT id FROM portal.application_checklist_statuses WHERE label = 'FAILED'),
       comment = 'BE-293 reconciliation: AWAIT_BPN_CREDENTIAL_RESPONSE failed without updating this entry',
       date_last_changed = now()
   FROM portal.company_applications ca
   WHERE ca.id = :'app'::uuid AND ac.application_id = ca.id
     AND ac.application_checklist_entry_type_id = (SELECT id FROM portal.application_checklist_types WHERE label = 'BPNL_CREDENTIAL')
     AND ac.application_checklist_entry_status_id = (SELECT id FROM portal.application_checklist_statuses WHERE label = 'IN_PROGRESS')
     AND (SELECT pss.label FROM portal.process_steps ps
          JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id
          JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
          WHERE ps.process_id = ca.checklist_process_id AND pst.label = 'AWAIT_BPN_CREDENTIAL_RESPONSE'
          ORDER BY ps.date_created DESC LIMIT 1) = 'FAILED'
     AND EXISTS (SELECT 1 FROM portal.process_steps ps
                 JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id
                 JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
                 WHERE ps.process_id = ca.checklist_process_id AND pst.label = 'RETRIGGER_REQUEST_BPN_CREDENTIAL' AND pss.label = 'TODO')
     AND NOT EXISTS (SELECT 1 FROM portal.process_steps ps
                     JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id
                     JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
                     WHERE ps.process_id = ca.checklist_process_id
                       AND pst.label IN ('REQUEST_BPN_CREDENTIAL', 'AWAIT_BPN_CREDENTIAL_RESPONSE') AND pss.label = 'TODO');
   SELECT (:ROW_COUNT = 1) AS exactly_one \gset
   \if :exactly_one
     COMMIT;
   \else
     ROLLBACK;
   \endif
   ```
   For `MEMBERSHIP_CREDENTIAL` the same statement uses `MEMBERSHIP_CREDENTIAL`, `AWAIT_MEMBERSHIP_CREDENTIAL_RESPONSE`,
   `RETRIGGER_REQUEST_MEMBERSHIP_CREDENTIAL` and `REQUEST_MEMBERSHIP_CREDENTIAL`. Expected output `UPDATE 1`,
   `COMMIT`; `UPDATE 0` rolls back and means the state changed: stop and re-run step 5.
   Undo (approval): the same statement with `FAILED` and `IN_PROGRESS` swapped and the comment restored from the
   step 5 output; it is only valid while the retrigger has not been sent.
7. **Re-check (read-only):** verdict `RETRIGGERABLE`.
8. **Approval: one retrigger**, only after deciding from C5 that a new request is wanted (if the holder already
   holds the credential, the retriggered await sees `ISSUED` and advances):
   `POST /api/administration/registration/application/{id}/retrigger-bpn-credential` (operator token read with
   `read -rs`, never echoed). Then watch C3/C4: `REQUEST_BPN_CREDENTIAL` → `AWAIT_BPN_CREDENTIAL_RESPONSE`.
   If it fails again, the fixed worker now leaves the entry `FAILED` with a comment and the retrigger is
   accepted directly; investigate the holder/issuer before retrying.
9. Never reset, skip or force-complete a step, never create credentials by hand, never retrigger twice in a row.

**BPDM membership field (separate, not changed).** The backend sends `memberships[].isArenaXMember` on
`PUT {pool}/cx-memberships` (commit `43767079b` "chore:ARENA branding"); BPDM `v7.5.0` (`CxMembershipDtoV6`) defines
`isCatenaXMember`. Before any change, confirm the live contract (read-only):
`curl -s https://business-partners.test.tractus-x.com/pool/docs/api-docs | ruby tools/bpdm_openapi.rb --api pool`
(`SCHEMA MISMATCH put cx-memberships` confirms). The step (`SET_CX_MEMBERSHIP_IN_BPDM`) runs at activation, after
the credentials.

## D. Housekeeping

- Second application `e6d0e7f3-d8ac-4310-bd84-0a94bf9c657c`: BPN PULL failed with
  `Duplicate identifier EU_VAT_ID_DE = DE123456789` (test data collision). Investigate read-only; do not change
  shared BPDM records.
- Reconcile tx-umbrella `develop`: its `be293-portal-images.yml` still builds `f5badda90`; the image builds ran
  from feature branches. Merge through reviewed PRs only.
- Merge the backend fix branch upstream to the BE-293 integration branch (review).
- Keep `.evidence/` out of Git (it holds full workload specs).

## E. Emergency references

| What | Command or value |
|---|---|
| Admin image before the fix | `…/portal-administration-service:be293-ad459ee7…@sha256:8d3b92f7…` (`.evidence/admin-before-rollout.yaml`) |
| Admin image now | `…/portal-administration-service:be293-274096a9…@sha256:aff600f9…` |
| Resolver drift check | `bash tools/did-resolver-be293.sh --diff` |
| Resolver probe | `bash tools/did-resolver-be293.sh --verify` |
| One-off DID retrigger (only while the entry is `FAILED`) | `POST /api/administration/registration/application/{id}/retrigger-validate-did`, operator token read with `read -rs`, never echoed |
