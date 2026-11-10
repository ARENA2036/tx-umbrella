# BE-293 Portal on STACKIT Alpha: release overlay, blockers and runbook (2026-11-05)

Target: kubeconfig `~/.kube/alpha.yaml`, context `alpha`, namespace `be293`, Helm release `be293-portal`.
**Status:** the operator installed the release. Revision 1 is `failed` after an install timeout, and live hotfixes stabilized it; see "Post-install stabilization". The agent sandbox cannot read `~/.kube/`. Cluster facts come from
the operator-run preflight of 2026-11-05:
- ExternalDNS 1/1, sources Ingress, covers `test.tractus-x.com`
- `letsencrypt-prod` Ready, using HTTP-01 with nginx
- both hosts free
- pull Secret present
- `keycloak`, `interfaces`, `identityhub` and `bdrs` FAIL

## Files added (all pre-existing files unchanged)

| File | Purpose |
|---|---|
| `values-be293-portal.alpha-release.yaml` | Overlay: hosts, both Ingresses (nginx, `letsencrypt-prod`, dedicated TLS Secrets, ExternalDNS hostname), fail-closed resolver |
| `networkpolicies-be293-portal.alpha-release.yaml` | Resolver/SMTP egress closed; ACME HTTP-01 solver ingress (needed: issuer is HTTP-01) |
| `expected-inventory.alpha-release.txt` | 29 objects + 2 Ingresses |
| `tools/render-release.sh` | Offline lint + render + release-mode gates + Ingress gates |
| `tools/validate_ingress.rb` | Ingress gates I1-I7 |
| `tools/alpha-preflight.sh` | Read-only preflight. Every command failure is a FAIL, never an OK |
| `tools/check_secret_contract.rb` | Checks one live Secret against the contract; never prints values |
| `tools/build_secret_manifest.rb`, `tools/create-be293-secret.sh` | Secure creation of one contract Secret (see "Supplying credentials") |
| `tests/test_validate_ingress.rb`, `test_check_secret_contract.rb`, `test_build_secret_manifest.rb` | Unit + offline integration tests |

## Secret classification (from the vendored portal-2.6.0 templates)

The chart **renders** `keycloak`, `interfaces`, `mailing` and `postgres` itself, through a `lookup` template:
- If the Secret exists, the chart reuses its data.
- If it does not exist, the chart fills `randAlphaNum 32` values.
- For `keycloak` and the owner keys of `interfaces`, those random values are **non-functional credentials**.
- For the 7 encryption keys they are **not** the 64 hex characters the contract requires.

`identityhub` and `bdrs` are **not** rendered. The workloads read them through `secretKeyRef` only.

| Secret | Rendered by chart | Supply | Ownership |
|---|---|---|---|
| `be293-portal-keycloak` | yes | pre-create **with** Helm adoption metadata. Owner credentials: `sa-cl1-reg-2` (CX-Central), `sa-cl1-reg-1` (master) | Helm adopts it; no conflict (see below) |
| `be293-portal-interfaces` | yes | pre-create **with** adoption metadata. Owner: `sa-cl7-cx-5` (BPDM), `sa-cl8-cx-1` (SD-Factory). Generated: 7 × 64-hex encryption keys. Unused keys are left to the chart | Helm adopts it |
| `be293-portal-identityhub` | no | pre-create **without** Helm metadata: `identityhub-api-key` (provisioner/admin on identity-hub-01), `issuerservice-admin-api-key` | external, never touched by Helm |
| `be293-portal-bdrs` | no | pre-create **without** Helm metadata: `management-api-key` (bdrs-server) | external |
| `be293-portal-postgres` | yes | **do not create**: chart-generated on first install | Helm |
| `be293-portal-mailing` | yes | **do not create** while mail is disabled: random passwords, mail fails closed | Helm |
| `be293-portal-registry-pull` | no | present (platform) | external |

**No ownership conflict:**
- Helm 4.3 adopts an existing object only if it carries `app.kubernetes.io/managed-by=Helm`, `meta.helm.sh/release-name=be293-portal` and `meta.helm.sh/release-namespace=be293`. `build_secret_manifest.rb` sets exactly these, and only on the two rendered Secrets.
- With server-side apply (Helm 4 default), the chart's `lookup` branch writes back the **same** data, so no field conflict arises.
- Without the metadata, `helm install` refuses the object. That is why `--take-ownership` (it skips the check) and `--force-conflicts` are **never** used.
- Consequence to accept: adopted Secrets become release-owned. A future `helm uninstall` would delete them, and the owners would re-supply them.

## Supplying credentials securely

1. The **owner issues** the credential: dedicated be293 clients/keys are preferred, because they rotate independently of the old Portal. Alternatively, the owner gives **written authorization** to reuse the existing one. Without one of the two, the Secret is not created.
2. The owner hands the value over through the team password manager or vault. Never through chat, email, a ticket or git.
3. The operator pastes it at the silent prompt of `tools/create-be293-secret.sh`. The value never touches disk, argv, env, shell history or the terminal. Encryption keys are generated in memory. `kubectl create` never overwrites.
4. Afterwards, the operator stores the 7 generated encryption keys in the vault. They encrypt data in the Portal database and are not recoverable if the Secret is lost.

```bash
bash tools/create-be293-secret.sh be293-portal-bdrs             # dry run: prompts, builds, contract-checks, sends nothing
bash tools/create-be293-secret.sh be293-portal-bdrs --execute   # same, then kubectl create in be293 on Alpha
# repeat for be293-portal-identityhub, be293-portal-keycloak, be293-portal-interfaces
```

## Remaining blockers

| ID | Blocker | Owner |
|---|---|---|
| **S1** | Issue or authorize, then hand over: `sa-cl1-reg-2`, `sa-cl1-reg-1` (Keycloak); `sa-cl7-cx-5`, `sa-cl8-cx-1` (Keycloak/BPDM/SD-Factory); identity-hub-01 provisioner key and IssuerService admin key; BDRS management key | Keycloak / IdentityHub / BDRS owners |
| **S2** | Create the 4 Secrets with `create-be293-secret.sh`; preflight P2 without FAIL | Operator, after S1 |
| **K1** | CentralIDP rejects the be293 redirect URIs (H6, 2026-11-05). Additive fix in CX-Central: `Cl2-CX-Portal` gets `https://portal-be293.test.tractus-x.com/*`, `Cl1-CX-Registration` gets `.../registration/*`, plus the web origin; existing values are kept. Run `tools/keycloak-k1.sh`. Blocks **login**, not install | Keycloak owner |
| R1 | No approved Universal Resolver with a stable egress destination. Onboarding DID validation fails closed | Platform/IdentityHub owners. Does not block install |
| M1 | SMTP credentials, authorization and egress destination for a REAL provider. Until then, test mail goes to smtp4dev (see "Test mail sink") | SMTP/platform owners. Does not block install |

## Safe installation procedure (after S1/S2; each step needs explicit approval)

Install **only** through `tools/install-be293.sh`. A manual `helm install` without all three values files and the `be293-retention` post-renderer would re-enable document deletion and drop the `keep` protection.

```bash
cd ~/Projects/ARENA2036/BE293_ALPHA/tx-umbrella/alpha/portal-release-prepared
KC=~/.kube/alpha.yaml
# 1. NetworkPolicies (be293 only, separate approval): server-side dry run, then apply.
kubectl --kubeconfig $KC --context alpha -n be293 apply --dry-run=server -f networkpolicies-be293-portal.alpha-release.yaml
kubectl --kubeconfig $KC --context alpha -n be293 apply -f networkpolicies-be293-portal.alpha-release.yaml
# 2. Default mode: offline gates + read-only preflight + NetworkPolicy check + server-side dry run. Installs nothing.
bash tools/install-be293.sh
# 3. After explicit approval: the same gates, a typed confirmation on the terminal, helm install, then verification.
bash tools/install-be293.sh --execute
```

What the wrapper enforces:
- Every call uses `--kubeconfig ~/.kube/alpha.yaml --kube-context alpha --namespace be293`.
- It always passes the 3 values files and `--post-renderer be293-retention`, with `HELM_PLUGINS` pointing at the release-local `helm-plugins/`.
- It aborts if the plugin is missing, if any offline gate (render, Ingress, retention D1-D8) fails, if the preflight reports a FAIL, or if a NetworkPolicy is missing.
- The dry-run release manifest is verified in memory: maintenance CronJob suspended, `keep` on postgres, keycloak and interfaces, PVC Retain/Retain, hooks equal to the 2 migration Jobs.
- After install it checks the **stored** manifest (`helm get manifest`/`hooks`) and the live CronJob, Secrets and PVC.
- It runs only `install`, `get`, `plugin` and `kubectl get`. It refuses `--replace`, `--take-ownership`, `--force-conflicts`, `--rollback-on-failure`, `--atomic` and `--force`.
- A failed install is left in place for read-only diagnosis.

## Post-install verification (read-only)

```bash
kubectl --kubeconfig $KC --context alpha -n be293 get pods,jobs,cronjobs,pvc,ingress,certificate,challenge
kubectl --kubeconfig $KC --context alpha -n be293 get pods -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' | grep -E 'ImagePull|ErrImage' || echo "no image pull errors"
kubectl --kubeconfig $KC --context alpha -n be293 logs job/be293-portal-portal-migrations --tail=50
kubectl --kubeconfig $KC --context alpha -n be293 logs job/be293-portal-provisioning-migrations --tail=50
bash tools/alpha-preflight.sh    # expected now: release present (FAIL by design), adopted Secrets OK
dig +short portal-be293.test.tractus-x.com; dig +short portal-backend-be293.test.tractus-x.com
curl -sS -o /dev/null -w '%{http_code} ssl=%{ssl_verify_result}\n' https://portal-be293.test.tractus-x.com/
curl -sS -o /dev/null -w '%{http_code} ssl=%{ssl_verify_result}\n' https://portal-backend-be293.test.tractus-x.com/api/administration/swagger/index.html
echo | openssl s_client -connect portal-be293.test.tractus-x.com:443 -servername portal-be293.test.tractus-x.com 2>/dev/null | openssl x509 -noout -issuer -enddate
```

## Offline verification (2026-11-05)

| Check | Result |
|---|---|
| `render-release.sh` | lint 0 failed; 31 objects, 0 placeholders, all gates PASS; Ingress gates PASS |
| `render.sh offline` (prepared state) | PASS |
| Tests | validate_render 30, check_package 10, validate_ingress 11, check_secret_contract 9, build_secret_manifest 5: 0 failures |
| Preflight, stub with every read denied | 53 FAIL, **0 OK**, exit 1 |
| Preflight, stub with Secrets absent | absent required Secrets FAIL; `postgres`/`mailing` absent OK; host conflict detected |
| Mutations (`resolver.example.org`, old Portal host) | rejected |

## Pre-install data-safety audit (2026-11-05, offline, source at `ad459ee7`)

**Database target:** one Portal-owned PostgreSQL in `be293`.
- **Service and storage:** StatefulSet `be293-portal-postgresql`, 1 replica, Bitnami `15-debian-11@sha256:e5dd5049…`, PVC `data-be293-portal-postgresql-0` (8Gi RWO, default StorageClass).
- **Credentials:** from Secret `be293-portal-postgres`.
- **Connection strings:** the render contains exactly two, both on `Server=be293-portal-postgresql;Database=postgres;Port=5432`:
  - user `portal` (schema `portal`), used by 5 Deployments, 2 CronJobs and `portal-migrations`
  - user `provisioning` (schema `provisioning`), used by 4 Deployments, `processes-worker` and `provisioning-migrations`
- **No other targets:** nothing points at another database host. NetworkPolicy blocks TCP 5432 outside `be293`.

**Migration Jobs** are hooks: `post-install,post-upgrade`, weight -5, no delete policy (so `before-hook-creation` applies), `restartPolicy: Never`.
- Both run `MigrateAsync` (pending migrations only) and then the seeders. No `EnsureDeleted`, reset or drop of schema or database exists in the code path.
- **Portal migrations:** 80 migrations.
  - Historical upstream `DELETE`/`Drop*` statements in `Up()` only touch tables created earlier in the same run, before seeding, so they are no-ops on an empty database.
  - The two BE-293 migrations are additive only: `CreateTable`, `CreateIndex`, `InsertData`.
- **Provisioning migrations:** 2 migrations. Blob SHAs are identical to upstream `v2.6.0`.
- **Seeders:**
  - `BatchInsertSeeder` inserts only missing keys.
  - `BatchUpdateSeeder` resets seed-keyed rows to seed values (companies, addresses, technical users, agreements, descriptions) **on every hook run**. That is harmless on install. On any later upgrade it overwrites UI edits to those rows, for example the operator company `BPNL00000003CRHK`.
- **Init scripts:** `01-init-db-user.sh` and `02-init-db.sql` (users, schemas, history tables) run only on an empty data directory.
- **Readiness:** `/health/startup` checks DB connectivity (`CanConnect`), not the schema, so `--wait` does not deadlock against the post-install hooks.

**Scheduled deletion (upstream design):** CronJob `portal-maintenance` runs daily at 00:00. It deletes `INACTIVE` documents older than 80 days that no company, connector or consent references. Only in this database.

**Helm, PVC and Secret behaviour**
- **PVC:** the PVC is created by the StatefulSet `volumeClaimTemplates` and is not a Helm object, so `helm uninstall` never deletes it. `persistentVolumeClaimRetentionPolicy` is unset, so the default is Retain/Retain.
- **Postgres Secret:** `be293-portal-postgres` has no `resource-policy: keep`. An uninstall would delete it while the PVC survives, and a reinstall would then generate new passwords that the existing database rejects. Back the Secret up to the vault after install.
- **Rendered Secrets:** `postgres`, `keycloak`, `interfaces` and `mailing` all use `lookup`, which preserves existing data. `lookup` returns empty only on NotFound, and other API errors fail the render. A pipeline of `helm template | kubectl apply` would bypass `lookup` and overwrite credentials and **encryption keys** with random values, making encrypted data unrecoverable. Never do that.
- **Adopted Secrets:** `keycloak` and `interfaces`, with adoption metadata, become release-owned. Back up the 7 generated encryption keys to the vault immediately after creation.
- **Hook Job names:** an existing Job named `be293-portal-{portal,provisioning}-migrations` would be **deleted** by Helm. Preflight P1b fails on it.
- **Leftover PVC:** an existing `data-be293-portal-postgresql-0` would be silently reused with mismatching new credentials. Preflight P1b fails on it, and the PVC must never be deleted to "fix" this.
- **Field conflicts:** with server-side apply and no `--force-conflicts`, an unexpected field conflict makes the install **fail** instead of overwriting. Not verifiable offline.

## Post-install stabilization (2026-11-05)

The first `helm install` timed out (release `failed`, revision 1). The operator applied four live hotfixes,
and every Deployment is now 3/3 Ready. Each hotfix now has a version-controlled source:

| Live hotfix | Root cause | Permanent fix |
|---|---|---|
| Supplementary NetworkPolicy for DNS port 8053 | NetworkPolicy matches the pod port after Service DNAT, and Gardener CoreDNS listens on 8053. The policy allowed only 53, so every lookup was blocked | `be293-portal-dns-egress` in `networkpolicies-be293-portal.alpha-release.yaml` now allows 53 and 8053 (UDP/TCP) |
| `ARENAADMINROLES` env on marketplace and services | The backend commit `43767079b` ("chore:ARENA branding", included in `ad459ee7`) renamed the `[Required]` setting `CatenaAdminRoles` to `ArenaAdminRoles`. The upstream chart renders only the old name. Source diff: the only other removed setting, `UseDimWallet`, is not rendered by the chart | The post-renderer copies each `<PREFIX>__CATENAADMINROLES__*` entry as `<PREFIX>__ARENAADMINROLES__*` with the same value, `Cl2-CX-Portal` / `CX Admin`, and keeps the Catena entry. Gate D9 and the release check verify this. `CX Admin` is still the seeded operator role in the fork |
| `custodian-client-secret` set to `disabled-custodian-no-access` | Keys marked `unused` were omitted from the pre-created Secret. For a key missing from an existing Secret, the chart writes `randAlphaNum 32` **unencoded** into `data:`, and Kubernetes decodes it into 24 random bytes, which can include a NUL (about 9% per key) | `build_secret_manifest.rb` writes the sentinel `disabled-<feature>-no-access` for every `unused` key. `check_secret_contract.rb` fails any key that contains a NUL byte |
| Manual Jobs `be293-portal-manual-{portal,provisioning}-migrations` | The migrations are `post-install` hooks and the install failed before they ran | Recovery uses `--no-hooks` (below). Later upgrades run the hooks normally; they are idempotent, and seed rows are pinned by D7 |

The live hotfixes stay in place. The rendered values match them, so after recovery they are co-owned
(server-side apply), not overwritten. Remove the supplementary DNS policy only in a separate, approved change,
after `be293-portal-dns-egress` with port 8053 is applied and verified.

### Recovery: `failed` to `deployed` (no reinstall, no hooks)

```bash
bash tools/health-check-be293.sh   # read-only external checks H1-H6 (frontend, TLS, API 401s, CORS, OIDC, redirect URIs)
bash tools/recover-be293.sh        # DEFAULT: dry run; changes nothing
bash tools/recover-be293.sh --execute   # only after approval: typed confirmation, then ONE helm upgrade --no-hooks
```

`recover-be293.sh` runs these checks and stops at the first failure:
1. Offline gates (D1–D10).
2. Release history is exactly `1 failed`.
3. Both manual migration Jobs succeeded, the PVC is Bound, both Secrets match the contract with no NUL byte, and port 8053 is allowed.
4. A server-side dry run (`helm upgrade --dry-run=server --no-hooks`) is checked in memory: the release checks pass, and `compare_release_live.rb` compares each rendered object with the live one. **Any Secret key that would change aborts.** Other drift is listed by field or env name only.

It never uses uninstall, rollback, install, `--force`, `--reset-values`/`--reuse-values`, `--force-conflicts`, `--atomic`, `--rollback-on-failure` or `--cleanup-on-fail`.

## Test mail sink: smtp4dev (2026-11-05)

There is no real SMTP provider yet (M1). Portal mail goes to **smtp4dev** in `be293`. It accepts and stores every message and relays none.

| File | Content |
|---|---|
| `smtp4dev-be293.alpha.yaml` | PVC (1Gi, default class), Deployment (`rnwood/smtp4dev:3.15.0`, pinned by index digest), ClusterIP Service `be293-smtp4dev:25` (SMTP only), NetworkPolicy (SMTP 2525 from be293 pods only). Not part of the Helm release |
| `values-be293-portal.alpha-smtp4dev.yaml` | Overlay in every render, install and recovery: processes-worker `MAILINGSERVICE__MAIL__SMTPHOST/PORT/USER` point at the sink. `password: ""` keeps the existing `be293-portal-mailing` data. The new-realm `PROVISIONING__SHAREDREALM__SMTPSERVER__*` settings are not overridden: they keep the live Office 365 configuration (decision 2026-11-08) |
| `tools/validate_smtp4dev.rb` | Gates S1–S9: be293 only, ClusterIP with SMTP only, digest pin, no relay plus LockSettings, IMAP/POP3 off, non-root with read-only FS, PVC and Recreate, policy, Portal mail to the sink, shared-realm SMTP kept as live (office365 nowhere else) |
| `tools/smtp4dev-be293.sh` | `--pin` (anonymous registry read, digest integrity) · default: dry run · `--execute`: create, patch the worker env, SMTP probe · `--verify` |

**Isolation:**
- There is no Ingress, LoadBalancer or NodePort. The UI is reachable only through `kubectl port-forward`.
- Relay is impossible for two independent reasons. `RelayOptions` is empty and `LockSettings=true`. Separately, be293 has no SMTP egress.
- The Portal mailer always authenticates (`Mailing.SendMail`). smtp4dev accepts any credentials and keeps none.

**Live change scope (`--execute`, after approval):**
- `kubectl create` the four objects. This never overwrites; it aborts if an object exists.
- Patch three non-secret env entries on the processes-worker CronJob. The next 5-minute run uses the sink, with no restart.
- Run one probe Job.

Shared-realm SMTP (the settings the Portal writes into each new shared-IdP realm) keeps the live Alpha configuration on administration and processes-worker: `smtp.office365.com:587` with the existing `be293-portal-mailing` Secret reference (decision 2026-11-08, pinned by gate S9). Only Portal mail sent by the processes-worker goes to the sink.

```bash
bash tools/smtp4dev-be293.sh --pin       # once, on an operator machine; review the digest diff
bash tools/smtp4dev-be293.sh             # dry run
bash tools/smtp4dev-be293.sh --execute   # after approval
kubectl --kubeconfig ~/.kube/alpha.yaml --context alpha -n be293 port-forward deploy/be293-smtp4dev 8085:8080   # http://localhost:8085
```

**End-to-end invitation test (needs K1 fixed):**
1. Log in as an operator (`CX Admin`).
2. Open "Invite business partner" and invite a test company with an address such as `test-admin@example.invalid`.
3. Within about 5 minutes (processes-worker schedule), smtp4dev shows the invitation mail ("Invitation to register for Arena-X") and the password mail ("Password required to register for Arena-X").
4. Open the registration link from the mail. It should go to `https://portal-be293.test.tractus-x.com/registration/`.

Mail steps that failed before the switch are not retried automatically. Create a new invitation instead.

## Keycloak IdP alias prefix (2026-11-05)

**Symptom:** "Add User" mails arrive in smtp4dev, but partner invitation mails don't.

**Root cause, confirmed in the live DB:** both invitations stopped at `INVITATION_CREATE_CENTRAL_IDP` with "Identity Provider idp2 already exists". Their applications are still `CREATED`, and no invitation mail was ever queued. Invitation mails are only queued at the end of the last step, `INVITATION_CREATE_USER`.
- The backend names each new IdP `Provisioning:IdpPrefix` + the next number from `provisioning.identity_provider_sequences` (`ad459ee7`: `IdpManagement.GetNextCentralIdentityProviderNameAsync`, `ProvisioningManager.CreateOwnIdpAsync`).
- The default prefix is `idp`, and be293's new provisioning database started again at 1.
- be293 shares CentralIDP `CX-Central` and SharedIDP with release26-09, which already uses `idp1`, `idp2`, and so on.
- The same name is also used for the shared realm and the service account client (`ServiceAccountClientPrefix` + alias).

**Fix:** `PROVISIONING__IDPPREFIX=be293-alpha-idp-` (configuration key `Provisioning:IdpPrefix`, `IdpManagementSettings` / `ProvisioningSettings`).
- It is set on the only two alias generators: the processes-worker (invitations) and the administration-service (own IdPs).
- The chart cannot render this setting, so the post-renderer inserts it after `PROVISIONING__CENTRALREALM`. The post-renderer refuses if the chart already renders the key.
- Gate D10 and the release check require exactly this value on both workloads, and no other prefix anywhere.
- New aliases are `be293-alpha-idp-<n>`, starting at `be293-alpha-idp-3` (1 and 2 were used by the failed attempts). **Never change the prefix once IdPs exist with it.**

| Tool | Purpose |
|---|---|
| `tools/diagnose-invitation-be293.sh` | Read-only: invitation steps, stored errors, IdP name sequence, queued mails, worker log errors |
| `tools/credential-status-be293.sh` | Read-only: BPN/Membership credential checklist entries, steps and the BE-293 await mismatch verdict for one application |
| `tools/keycloak_alias_check.rb` | Read-only: proves `<prefix>1..n` is unused as a central IdP alias, a shared realm and a shared master client. It uses GET requests with the worker's own service accounts, after control probes against a known alias |
| `tools/idp-prefix-be293.sh` | Default: dry run (gates, live env, DB, Keycloak probe, server-side dry-run patches that may add only this one entry). `--execute`: patch both workloads. `--retrigger`: retrigger the eligible failed invitations through the Portal API. `--verify`: read-only |

**Retrigger** (`POST /api/administration/invitation/{processId}/retrigger-create-central-idp`, role `invite_new_partner`):
- It reuses the same process, company and application. The backend accepts it only while `RETRIGGER_INVITATION_CREATE_CENTRAL_IDP` is TODO, then schedules `INVITATION_CREATE_CENTRAL_IDP` again. That step takes a new sequence number and overwrites `idp_name`.
- Preconditions:
  - The prefix is live on both workloads.
  - The admin rollout is complete.
  - No worker Job that started before the patch is still running.
  - The Keycloak probe passes.
  - Exactly 2 invitations are eligible: central step FAILED, retrigger step TODO, nothing else pending, no `idp_name`, not locked.
- The token must be from CX-Central, carry the role `invite_new_partner` and be valid for more than 120 s. It is read hidden from the terminal and passed to curl only through `--config` on stdin.

The live patch and the later Helm recovery render the same entry, so server-side apply co-owns the field and nothing conflicts.

## BPDM Gate and Pool API version (2026-11-06)

**Symptom:** BPN creation fails with HTTP 404 at `https://business-partners.test.tractus-x.com/gate/input/business-partners`.

**Root cause, in code:**
- The backend (`ad459ee7`, `BpdmService.PutInputLegalEntity`) sends `PUT input/business-partners` relative to `APPLICATIONCHECKLIST__BPDM__BASEADDRESS` + `/`.
- The chart builds that address as `bpdm.portalGateAddress` + `bpdm.portalGateApiPath`. Our values had `/gate` and `/pool`, so the API version segment was missing.
- The BPDM Ingress only strips the `/gate` or `/pool` prefix (umbrella reference: `/gate(/|$)(.*)` with `rewrite-target: /$2`). The request therefore reached the Gate as `/input/business-partners`, which has no handler.
- **The host is correct; the path lacks `/v6`.**
- References: portal-2.6.0 chart default `/companies/test-company/v6`; umbrella 3.17.0 `/gate/v6` and `/pool/v6` with BPDM 7.2.0.

**Fix:** `bpdm.portalGateApiPath: /gate/v6` and `bpdm.poolApiPath: /pool/v6` in `values-be293-portal.yaml`.
- The chart feeds these to the processes-worker, administration, registration and portal frontend: 8 env entries.
- Gate R-BPDM (`validate_render.rb`) requires `https://business-partners.test.tractus-x.com/{gate|pool}/v<N>` with one version everywhere. It also rejects any other env that points at BPDM.

| Tool | Purpose |
|---|---|
| `tools/bpdm-endpoint-be293.sh` | Default, read-only: offline gates, be293 live env, release26-09 Portal reference env, BPDM Ingress routes and images (`get` only), live Gate/Pool OpenAPI (anonymous GET), verdict, and a server-side dry run of the worker patch. `--execute`: patch only the two worker env entries. `--verify`: read-only |
| `tools/bpdm_openapi.rb` | Derives the API version prefix that serves **every** backend call. Gate: `PUT input/business-partners`, `POST sharing-state/ready`, `POST output/business-partners/search`, `GET sharing-state`. Pool: `PUT cx-memberships`, `GET legal-entities/{bpn}` |
| `tools/env_patch.rb` | Plain env patch, built from the gated render and asserted: the dry run may change only the named entries |

**Live scope:** only the processes-worker, which runs the BPN steps. It takes effect on the next Job, with no restart.
- The administration and registration `BPNACCESS__BASEADDRESS` (BPN lookup) and the frontend `BPDM_*_API_URL` are corrected by the approved Helm recovery; patching them live would restart them.
- The failed BPN step is not retriggered by the script. That needs a separate approval.

### Compatibility with shared BPDM 7.5.0

Checked against the `eclipse-tractusx/bpdm` tag `v7.5.0` (`d68601e7`) sources, comparing the backend's request and response records with the BPDM DTOs.

| Call (backend `ad459ee7`) | BPDM 7.5.0 `/v6` | `/v7` |
|---|---|---|
| Gate `PUT input/business-partners` | Yes: same `BusinessPartnerInputRequest` as v7; every field sent exists (nulls are omitted) | yes |
| Gate `POST sharing-state/ready` `{externalIds}` | Yes (204) | no: moved to `business-partners/sharing-state/ready` |
| Gate `POST output/business-partners/search` | Yes: v6 `BusinessPartnerOutputDto` (`legalEntity.legalEntityBpn`) | yes, but the v7 DTO |
| Gate `GET sharing-state?externalIds=` | Yes: v6 `SharingStateDto`, enum `Pending/Success/Error/Initial/Ready` | no: moved to `business-partners/sharing-state` |
| Pool `GET legal-entities/{bpn}?idType=BPN` | Yes: `legalForm` object, typed identifiers | n/a |
| Pool `PUT cx-memberships` | Path yes. **Body no:** BPDM expects `isCatenaXMember`; the ARENA "branding" commit `43767079b` sends `isArenaXMember` | no: replaced by `data-space-participants` |

- **Result:** `/v6` is the only version that serves the pinned backend, and every BPN Creation call is compatible.
- **`cx-memberships` body:** this is a backend defect, not configuration. It affects the later activation step `SET_CX_MEMBERSHIP_IN_BPDM`, not BPN Creation. The same rename affects the read-only `isArenaXMemberData` (BPDM sends `isCatenaXMemberData`), which then defaults to `false`.
- **Live check:** `tools/bpdm_openapi.rb` re-checks these fields against the live OpenAPI. A Gate mismatch aborts; a Pool mismatch prints `WARN`.

### Retrying BPN Creation (separate approval)

1. **Confirm the worker addresses (read-only):** `bash tools/bpdm-endpoint-be293.sh --verify` shows the worker on `/gate/v6` and `/pool/v6`.
2. **Check eligibility (read-only):** `bash tools/bpdm-endpoint-be293.sh --bpn-status`. An application is eligible when its `BUSINESS_PARTNER_NUMBER` entry is `FAILED` and `RETRIGGER_BUSINESS_PARTNER_NUMBER_PUSH` is `TODO`. A 404 is a received response, so it is not recoverable (`RecoverOptions.INFRASTRUCTURE`): the step failed and was not retried automatically.
3. **Retrigger once per application:** an operator with `approve_new_partner` uses the retrigger action on the application's BPN checklist item in the Portal admin UI. That action calls `POST /api/administration/registration/application/{applicationId}/trigger-bpn?processTypeId=RETRIGGER_BUSINESS_PARTNER_NUMBER_PUSH` and expects 204. It schedules `CREATE_BUSINESS_PARTNER_NUMBER_PUSH` for the next worker Job, and no new company or application is created.
4. **Next Job:** `PUT /gate/v6/input/business-partners` runs. It is an upsert keyed by the application id, so repeating it is safe. Then `POST …/sharing-state/ready`, then `CREATE_BUSINESS_PARTNER_NUMBER_PULL` polls `sharing-state`. Pull stays `TODO` until the shared golden-record process reports `Success`, then the BPNL is written to the company.
5. **Verify (read-only):** run `--bpn-status` again. Expect PUSH `DONE`, PULL `TODO`, then `DONE`, and the entry `DONE`. A Gate `Error` state fails the PULL with the BPDM error code.

## DID validation and checklist retrigger: permanent configuration (2026-11-07)

**What runs on Alpha.** Only `portal-administration-service` runs the `274096a9` build (DID validation retrigger resumes `IDENTITY_WALLET` in `IN_PROGRESS`, digest `aff600f9…`). The other seven backend images stay on their live `ad459ee7` digests. `images.lock.yaml` records exactly that under `rebuilt` (what Helm renders); the seven `274096a9` builds that were published but not deployed are listed under `publishedNotDeployed`, which gate G4 never lets into a render. `tools/record_portal_images.rb` edits only `rebuilt`.

**Worker resolver.** `values-be293-portal.alpha-release.yaml` sets both `APPLICATIONCHECKLIST__{IDENTITYHUB,DIM}__UNIVERSALRESOLVERADDRESS` to `http://be293-did-resolver.be293.svc.cluster.local:8080/` (gate DR9), the values the live CronJob already has.

**DID resolver lifecycle.** `did-resolver-be293.alpha.yaml` (Deployment, Service, gateway ConfigMap, ingress and egress NetworkPolicy) is a separately managed, digest-pinned manifest, deliberately not part of the Helm release: gate DR11 fails if the release ever renders an object with the same kind and name, so a Helm upgrade, rollback or uninstall never adopts or deletes it. Drift check: `bash tools/did-resolver-be293.sh --diff` (read-only; refuses if an object carries Helm ownership). Moving it into Helm later needs its own approved migration (ownership labels/annotations, no recreate).

**Read-only diff before any upgrade.** `bash tools/helm-diff-be293.sh`: offline gates, release history, the image each workload runs now, a server-side dry run compared in memory with the live objects (no values printed), and the resolver diff. Expected with the current pins: no image change for any workload and no change of the worker resolver variables. An upgrade uses server-side apply without `--force-conflicts`, so a field set live by `kubectl` with a different value makes the upgrade fail instead of overwriting it.

**Rollback.**
- Administration image: `kubectl rollout undo deployment/be293-portal-administration-service` (or `set image` to the `ad459ee7…@sha256:8d3b92f7…` image recorded in `.evidence/admin-before-rollout.yaml`), then restore that digest in `images.lock.yaml` and `values-be293-portal.yaml` before any Helm operation. `helm rollback` to an older revision would also bring back the old image.
- Worker resolver variables: patch both back (previous values in `.evidence/processes-worker-before-resolver.yaml`), only together with the values overlay.
- Frontend (once a BE-293 build is deployed): set `frontend.portal.image` back to `docker.io/tractusx/portal-frontend:v2.6.0@sha256:d0fe6dd2…` (still recorded under `upstream` in the lock) and roll the portal Deployment.

**Checklist retrigger in the UI.** The upstream `v2.6.0` frontend has no endpoint for `RETRIGGER_VALIDATE_DID_DOCUMENT` (`POST …/undefined`, 404) and fires every listed alternative at once. The fix (`ci/portal-frontend-checklist-retrigger.patch`, on top of upstream `v2.6.0`) is not deployed yet; until then use the API directly, once, for a step whose entry is `FAILED`.

## Residual risks

- After install, the chart adds unused keys (`identityhub-api-key`, `bpndidresolver-api-key`, ...) to `be293-portal-interfaces`. Preflight then shows a WARN for undeclared keys, which is expected.
- Job/CronJob pods have no labels, so in-namespace rules cover every pod in `be293`. The namespace must host only this release.
- `release26-09` may have its own ingress-side NetworkPolicies that drop traffic from `be293`. That is the owners' decision.
- Reusing the seeded service accounts, instead of dedicated clients, shares rotation with the old Portal.
- The `ArenaAdminRoles` post-render shim depends on the fork. If a future chart renders `ARENAADMINROLES` itself, the post-renderer refuses, so remove the shim at that point.
- Upgrade over the manual hotfixes: if a kubectl-owned field would get a **different** value, server-side apply fails instead of overwriting it (no `--force-conflicts`). Revision 2 is then `failed` and nothing is deleted.
- The other `unused` keys in the live `be293-portal-interfaces` (clearinghouse, dim, issuercomponent, offerprovider) still hold the chart's random bytes, without NUL, since the pods start. They are harmless while unused. Replace them with sentinels only through a separate, approved patch of those keys.
