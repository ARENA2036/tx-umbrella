# BE-293 Alpha — Phase 7 preflight: own IdentityHub, IssuerService, Vault and BDRS in `be293`

**Date:** 2026-11-17 · **Type:** investigation and plan only. Nothing was implemented, deployed or changed.
**Inputs:** roadmap v5 (`docs/dev/BE-293-alpha-portal-test-replica-roadmap-v5.md`), Phase 1 report, DCP contract doc,
`alpha/portal-release-prepared/`, the pinned umbrella (`handoff/BE-293-umbrella-3.17.0/`), the DEV blueprint
(`~/Backup/Projects/public-tractus-x-umbrella`, `~/Backup/Projects/public-tractusx-identityhub-be293`), Portal backend
`portal-backend-await-fix` @ `e2451f876`, and EDC 0.17.0 jars from the local Gradle cache.

**Classification.** **VERIFIED**: read in source, chart, bytecode or a recorded observation, with the reference given.
**INFERRED**: reasoning from verified facts, not observed. **NOT VERIFIED**: needs a live read I could not make.

**Cluster access.** None from this workstation: the agent sandbox cannot read `~/.kube/alpha.yaml`. Every statement
about live `release26-09` or `be293` state in this report is therefore either carried over from earlier recorded
observations (cited) or NOT VERIFIED. §3.4 lists the exact read-only commands to run.

---

## 1. Current architecture and dependencies

`walletProvider: IdentityHub` (`values-be293-portal.yaml:87`). The Portal is at revision 6 on our own Keycloaks (given).

| Component | Where it runs | Used for | Authentication from the Portal | Status |
|---|---|---|---|---|
| CentralIDP / SharedIDP | `be293` (`centralidp-be293`, `sharedidp-be293`) | login, realms, IdPs, provisioning | `sa-cl1-reg-2` / `sa-cl1-reg-1` client credentials | given |
| BPDM Gate/Pool | public testbed `business-partners.test.tractus-x.com` | BPN, sharing state | machine token from the **shared** CentralIDP, `sa-cl7-cx-5` (G1-1) | VERIFIED (`values-be293-portal.yaml:199-206`) |
| IdentityHub (identity/admin API) | `release26-09`, `identity-hub-01` Service port 8082 | create and activate holder participant context, request credentials, poll request state | `x-api-key` from Secret `be293-portal-identityhub` key `identityhub-api-key` | VERIFIED (`values-be293-portal.yaml:218,232`; `IdentityHubService.cs:46-125,205-216`) |
| IdentityHub public endpoints | `identity-hub-01.test.tractus-x.com` | DID documents (`didDocumentBaseLocation`), CredentialService URL baked into each holder DID | none (public) | VERIFIED (`values-be293-portal.yaml:219-220`) |
| IssuerService (admin API) | `release26-09`, `issuer-service` port 8086 | register holder (`POST …/participants/issuer/holders`) | `x-api-key` from `be293-portal-identityhub` key `issuerservice-admin-api-key` | VERIFIED (`values-be293-portal.yaml:224,233`; `IdentityHubService.cs:179-203`) |
| IssuerService (DCP issuance, DID, status list) | `release26-09`, public `issuer-service.test.tractus-x.com` | issues to the holder on IdentityHub's request; issuer DID `did:web:issuer-service.test.tractus-x.com:BPNL00000003CRHK` | DCP (self-issued tokens between IdentityHub and IssuerService); the Portal does not call it | VERIFIED (`values-be293-portal.yaml:130,222`) for the DID; INFERRED for the call chain |
| Vault(s) for IdentityHub / IssuerService | `release26-09`, **in-memory** | holder keys, STS secrets, API-token hashes | none from the Portal | VERIFIED as recorded (v5 §4.7, Saud's confirmation) |
| BDRS management API | `release26-09`, `bdrs-server` port 8081 | `TransmitDidAndBpn` at the wallet step | `X-Api-Key` from Secret `be293-portal-bdrs` key `management-api-key` | VERIFIED (`values-be293-portal.yaml:44-48`; report item 8) |
| BDRS directory | public `bdrs-server.test.tractus-x.com/api/directory` | BPN→DID lookups in services, administration, marketplace, frontend | per BDRS directory rules | VERIFIED (report item 8 table) |
| DID resolver | `be293`, `be293-did-resolver` | `VALIDATE_DID_DOCUMENT` resolves the holder `did:web` over public HTTPS | none | VERIFIED (`values-be293-portal.alpha-release.yaml:106-114`) |
| SD Factory | `release26-09`, `sdfactory` | self-description | `sa-cl8-cx-1` (now token address on centralidp-be293) | VERIFIED configured; **not called** while `clearinghouseConnectDisabled` (v5 §2.1 4a) |
| IdentityHub → Portal callback | `portal-credential-callback` extension in our IdentityHub fork | BPN/Membership callback | OAuth client credentials against `TX_PORTAL_CALLBACK_TOKEN_URL` | VERIFIED as a contract (DCP contract doc §2); NOT VERIFIED whether `release26-09` runs this extension (it runs chart **v0.4.2**, `alpha-service-map.yaml:6`) |

The worker CronJob and the maintenance CronJob are suspended (given; v5 §4.6 records the worker suspension since
2026-11-13, and revision 6 renders it, see `helm-plugins/be293-idp-switch/post-render.rb`).

## 2. Every path that can write to `release26-09`

Onboarding order, as the code runs it. All entries VERIFIED in source unless marked.

| # | Step (checklist) | Call | Write in `release26-09` | Setting that points at it | After Phase 7 |
|---|---|---|---|---|---|
| W1 | `IDENTITY_WALLET` → create wallet | `POST {identityHub.baseAddress}/v1alpha/participants` (`IdentityHubService.cs:75`) | new participant context in IdentityHub DB; generated EC key pair and STS client secret in its Vault (INFERRED from the request body: `KeyGeneratorParams("EC","secp256r1")`, `:55-64`) | `backend.processesworker.identityHub.baseAddress` = `http://identity-hub-01.release26-09…:8082/api/identity` (`values-be293-portal.yaml:218`) → env `APPLICATIONCHECKLIST__IDENTITYHUB__BASEADDRESS` | our IdentityHub Service in `be293` |
| W2 | same step → activate | `POST …/participants/{ctx}/state?isActive=true` (`:78`) | participant state | same | same |
| W3 | same step → DID references | holder DID `did:web:identity-hub-01.test.tractus-x.com:<bpn>`, CredentialService `https://identity-hub-01.test.tractus-x.com/api/credentials/v1/participants/<ctx>` (`:50-53`) | none directly; it **binds the holder's identity to their host** | `didDocumentBaseLocation`, `credentialServiceBaseAddress` (`values-be293-portal.yaml:219-220`) | our public IdentityHub host |
| W4 | `IDENTITY_WALLET` → `TRANSMIT_BPN_DID` | `POST {BPNDIDRESOLVER__BASEADDRESS}/api/management/bpn-directory` (report item 8; `BpnDidResolverBusinessLogic.cs:88`) | BPN→DID row in the shared BDRS | `bpnDidResolver.managementApiAddress` = `http://bdrs-server.release26-09…:8081` (`values-be293-portal.yaml:45`) | our BDRS management Service in `be293` |
| W5 | `BPNL_CREDENTIAL` / `MEMBERSHIP_CREDENTIAL` → register holder | `POST {issuerAdminBaseAddress}/v1alpha/participants/issuer/holders` (`IdentityHubService.cs:179-203`) | holder row in the shared IssuerService | `identityHub.issuerAdminBaseAddress` (`values-be293-portal.yaml:224`), `issuerParticipantId: issuer` | our IssuerService admin Service |
| W6 | same → request credential | `POST {identityHub}/v1alpha/participants/{ctx}/credentials/request` (`:118-122`) | holder credential request in IdentityHub; **then** IdentityHub calls the issuer named by `issuerDid` | `identityHub.baseAddress`, `identityHub.issuerDid` (`values-be293-portal.yaml:222`), admin `issuerdid` (`:130`) | our IdentityHub; our issuer DID |
| W7 | (indirect, from W6) DCP issuance | IdentityHub → IssuerService DCP endpoint (resolved from the issuer DID document) → IssuerService writes the credential to the holder's CredentialService | issuance process, credential, status-list entry in IssuerService; stored credential in IdentityHub | **only** `issuerDid` and the holder's IdentityHub; the Portal cannot reach this path directly | moves with W5/W6. INFERRED from the DCP flow |
| W8 | callback (IdentityHub → Portal) | `TX_PORTAL_CALLBACK_*` | none in `release26-09` (it writes to the Portal) | IdentityHub release config | our IdentityHub; the callback client must exist in `centralidp-be293` (KNOWN LIMITATIONS, previous turn) |
| W9 | `SELF_DESCRIPTION_LP` | SD Factory | would write | `sdfactoryAddress` = `http://sdfactory.release26-09…` (`values-be293-portal.yaml:42`) | **inactive** today (`clearinghouseConnectDisabled`); recommend `https://sdfactory.disabled.invalid` (decision D7-9) |
| W10 | BPDM machine token | shared CentralIDP token endpoint | token issuance only; Keycloak may record events if event storage is on — INFERRED, NOT VERIFIED | `backend.processesworker.bpdm.tokenAddress` | **unchanged** (G1-1, out of scope) |

**Network-level evidence today.** NetworkPolicy `be293-portal-release26-09-egress` opens exactly four
`release26-09` destinations: `identity-hub-01:8082`, `issuer-service:8086`, `bdrs-server:8081`, `sdfactory:8080`
(`networkpolicies-be293-portal.alpha-release.yaml:98-150`). VERIFIED. After Phase 7 the whole policy is deleted.
**Residual hole (INFERRED):** the public-ingress rule allows HTTPS to the shared ingress address; every public
`release26-09` host (including `issuer-service.test…`, `identity-hub-01.test…`, `bdrs-server.test…`) sits behind it.
NetworkPolicy alone therefore cannot prove "zero writes"; configuration plus a grep gate must (A12, v5 §4.8).

## 3. The HTTP 500

### 3.1 What is being called
`POST http://identity-hub-01.release26-09.svc.cluster.local:8082/api/identity/v1alpha/participants`. This is W1: the
**first** authenticated call of the onboarding, made with the IdentityHub super-user key from `be293-portal-identityhub`.
VERIFIED (`IdentityHubService.cs:75,205-209`).

### 3.2 Correction to the premise
The task statement merges two prior findings into one path. Roadmap v5 §4.7 records them **separately**:
1. **BPN-credential 500** (issuer side, credential issuance): `holderId = BPN` against a DID-keyed
   `custom_attestation_claims` database attestation → no row → `success(null)` → `putAll(null)` NPE. VERIFIED prior work.
2. **Incident 2026-11-12**: after the in-memory Vaults lost key material, "IssuerService super-user key → 401;
   IdentityHub 01 → 500 (NPE in `ParticipantServicePrincipalResolver`)". VERIFIED prior observation.

`ParticipantServicePrincipalResolver` belongs to (2), not to (1).

### 3.3 Where `ParticipantServicePrincipalResolver` sits (VERIFIED, bytecode)
`org.eclipse.edc.identityhub.api.ParticipantServicePrincipalResolver` in
`identityhub-api-authentication-lib-0.17.0.jar` (Gradle cache; `javap -c`):
- `findByCredential(apiKey)`: splits the key on `.`, base64-decodes the first part to a participant id, calls
  `findByPrincipal(id)`, then `principal.getCredential().equals(apiKey)`.
- `findByPrincipal`: loads the participant context from the **database**; failure → `AuthenticationFailedException` (401).
- `toUser`: `credential = vault.resolveSecret(participantId, apiTokenAlias)` — read from the **Vault**.
- If the participant exists in the database but its API token is gone from the Vault, `getCredential()` is `null`
  and `null.equals(…)` throws an NPE → HTTP **500**, not 401.

This runs for **every** authenticated identity-API request, **before** the participant-creation logic.

### 3.4 Verdict
- **VERIFIED:** a 500 on this endpoint is produced by exactly this resolver when the super-user context survives in
  the database but its token is missing in the Vault. That is the 2026-11-12 IdentityHub-01 failure class.
- **VERIFIED:** it is **not** the BPN-credential path (1). That path is on the issuer, during issuance, and is reached
  only after the wallet step has succeeded.
- **INFERRED (most likely):** this 500 is path (2). The key would be in the database but not in the in-memory Vault if the
  Vault was emptied after the super-user was created. `SuperUserSeedExtension` acts only when the super-user does
  **not** exist (`SuperUserSeedExtension.java:75`, report item 9), so a restart never repairs it.
- **NOT VERIFIED:** that this particular 500 is the resolver NPE. Other causes on the same endpoint remain possible:
  a Vault **write** failure while storing the generated key pair or STS secret, or a database error. I do not treat
  the in-memory storage as the cause without the log line.

**Read-only commands that settle it** (no exec, no secrets; run from your Mac, `K` = your kubectl function):
```bash
K -n release26-09 get pods -o wide | grep -E 'identity-hub-01|vault'                  # restart times: Vault vs IdentityHub
K -n release26-09 logs deploy/identity-hub-01 --since=72h \
  | grep -E 'NullPointerException|ParticipantServicePrincipalResolver|resolveSecret|Vault|ERROR' | grep -v -i 'api key' | tail -40
K -n release26-09 logs deploy/identity-hub-01 --since=72h | grep -c 'participants'
```
Decisive pattern: a stack trace with `ParticipantServicePrincipalResolver.findByCredential` → path (2). A Vault or
"secret" error inside participant creation → a different failure (key generation/storage). The filter excludes the
first-boot "API Key" line on purpose (§5.6).

Optional, needs your approval: one authenticated **GET** (`/v1alpha/participants?limit=1`) with the Portal's key
also returns 500 under path (2). It reads only, but it is an API call into `release26-09`, not a Kubernetes read.

**Consequence for Phase 7:** whatever the root cause, our own IdentityHub must never pair a persistent database with
a non-persistent Vault. That is the single design rule behind §5.

## 4. What already exists and is reusable

### 4.1 Pinned charts (handoff umbrella `charts/`, sha256 prefix)
| Chart | Version | sha256 (first 16) | Notes |
|---|---|---|---|
| `identity-and-trust-bundle-1.2.0.tgz` | 1.2.0 | `c763c8148cbf9263` | **No templates of its own** (0 files under `templates/`). Wrapper over `ssi-dim-wallet-stub` 0.1.14, `tractusx-identityhub-memory` v0.3.2 (alias `identity-hub`), `tractusx-identityhub` v0.3.2 (alias `identity-hub-postgres`), `tractusx-issuerservice` v0.3.2 (alias `issuer-service`). VERIFIED |
| `tractusx-identityhub-v0.3.2.tgz` | v0.3.2 | `701a26264eb41351` | Same `values.yaml` as the bundle's copy (`cmp` equal). VERIFIED. **Differs from the published digest; content never compared** (`VALIDATION.md:78`) |
| `tractusx-issuerservice` | v0.3.2 | only inside the bundle | no standalone tgz pinned. VERIFIED |
| `bdrs-server-0.6.0.tgz` | 0.6.0 | `f7fe905a7d6eddeb` | PostgreSQL-backed; **differs from the published digest, never compared** (`VALIDATION.md:78`) |
| `bdrs-server-memory-0.6.0.tgz` | 0.6.0 | `2658dffb8188aa79` | **Do not use** (v5 §4.3) |
| `ssi-credential-issuer-1.4.0.tgz` | 1.4.0 | `b3e7b24587a626c0` | old issuer component, **not** IssuerService; not needed |

Chart defaults wrong for us (VERIFIED, bundle `charts/tractusx-issuerservice/values.yaml:392-410`, same in IdentityHub
`:409-420`): `vault.server.dev.enabled: true`, `devRootToken: "root"`, `vault.hashicorp.token: "root"`, bundled
PostgreSQL `18.0@sha256:1ffc019d…`. BDRS: dev Vault with root token, PostgreSQL persistence off, password `"password"`
(report item 8).

**Version gap (VERIFIED from records, consequence INFERRED).** `release26-09` runs the IdentityHub and IssuerService
charts **v0.4.2** (`alpha-service-map.yaml:6,10`). The roadmap records images `tractusx/issuerservice:0.4.1` and
`tractusx/identityhub:0.4.1` as pullable (v5 §4.7). The Portal client was written against EDC/IdentityHub **0.17.0**
APIs (`IdentityHubService.cs:49`). The DEV blueprint ran our fork images `identityhub-3633af-r1@sha256:5c054895…` and
`issuerservice-3633af-r1@sha256:8ee74272…` from a personal Docker Hub repository
(`values-be293-k8s-dev-01-images.yaml:24-35`), with the `portal-credential-callback` extension
(`public-tractusx-identityhub-be293/extensions/`). Which chart/image pair we deploy is decision D7-2.

### 4.2 Bundle as-is versus discrete releases
**Bundle as-is: no.** It adds nothing but aliases (no templates). It carries a wallet stub we do not want and two
IdentityHub variants, and every subchart defaults to a dev-mode root-token Vault. Making it safe means overriding the same
things as discrete releases, with one shared release lifecycle: a failed IdentityHub upgrade would also roll the issuer.
**Recommendation: discrete releases** (as for the two Keycloaks): `be293-identity-vault`, `be293-issuerservice`,
`be293-identityhub`, `be293-bdrs`, plus their PostgreSQL. Each has its own values file, dry run, verification and rollback.

### 4.3 DEV seed job (VERIFIED, report item 9)
`tx-data-provider/templates/post-install-identityhub-seed.yaml` (1102 lines) creates and activates the issuer context,
posts attestations, credential definitions and holders, then creates the holder and requests credentials. Reusable:
**the call sequence and the proven attestation/definition bodies** (`holders-database-attestation`,
`holder-properties-attestation`, `tx-bpncredential` mappings, v5 §4.7). Not reusable: the key discovery by grepping
pod logs (and the `pods/log` RBAC), and the DEV Membership definition (no `memberOf`).

### 4.4 Release-package conventions to follow (VERIFIED)
`alpha/portal-release-prepared/`: `values-be293-*.yaml`; `images.lock.yaml`; `secrets-contract.yaml` (key names only);
`expected-inventory*.txt`; `networkpolicies-*.yaml` applied separately; offline gates in `tools/render-release.sh`;
guarded wrappers (`upgrade-be293.sh`, `switch-idp-be293.sh`: read-only `k()`/`h()`, refused flags, chart sha256 pin,
evidence snapshot, typed confirmation, `--no-hooks`, expected-drift file); Ruby tests under `tests/` (227 runs green).
BDRS-specific pattern in the umbrella (`be293Provisioning`): Raft Vault with PVC, write-once init container
`files/be293-bdrs-vault-provision.sh`, `networkpolicy-bdrs-vault.yaml`, `post-install-bdrs-setup.yaml` (report item 8).

### 4.5 Does the BDRS provenance gap matter?
**Yes, for Phase 7 specifically.** We would deploy that chart into `be293`, and it handles a management API key and
database credentials. An unexplained local difference could change how those are handled. P3-4 (compare against
the published 0.6.0, classify every difference) must run **before** the BDRS step. The same gap applies to
`tractusx-identityhub-v0.3.2.tgz` (`VALIDATION.md:78`). It does not apply to a v0.4.2 chart we would pull fresh and
pin, if D7-2 chooses that. INFERRED.

## 5. What is missing or blocks deployment

| # | Item | State | Class |
|---|---|---|---|
| 5.1 | **Versions**: chart/image pair (D7-2); images by digest in a registry we control (the DEV images live in a personal Docker Hub repo) | open | VERIFIED gap |
| 5.2 | **Public DNS + TLS** for at least `identityhub-be293.test.tractus-x.com` (holder DIDs, CredentialService) and `issuer-be293.test.tractus-x.com` (issuer DID, DCP issuance, status list); `bdrs-be293…` only if D7-6 says so. ExternalDNS reconciliation on Alpha is **not verified** (v5 §4.6, D2). `letsencrypt-prod` rate limits apply | open | NOT VERIFIED |
| 5.3 | **PostgreSQL**: one instance per app or one instance with three databases and users (D7-4); PVC on `premium-perf1-stackit` (confirmed for the Portal PVC, previous turn); `persistentVolumeClaimRetentionPolicy` Retain like the Portal | open | INFERRED |
| 5.4 | **Vault**: Raft storage on a PVC, `dev.enabled: false`, TLS inside the cluster optional (ClusterIP plus NetworkPolicy); KV v2 at the path the charts expect (`/v1/secret/data`) | open | VERIFIED requirement (v5 §3) |
| 5.5 | **Vault auth and unseal.** EDC's HashiCorp Vault client uses a **token** (`edc.vault.hashicorp.token`, renewable). Kubernetes auth is not offered by the client. INFERRED (not checked in the 0.17 jar). Proposal: one Vault policy per app (read/write only its own path), one **periodic, non-root** token per app in a K8s Secret, injected by `secretKeyRef` (the BDRS chart supports `server.envValueFrom.EDC_VAULT_HASHICORP_TOKEN`, report item 8). The root token is revoked after setup. **Unseal**: Shamir keys held offline by the operator, manual unseal after every Vault pod restart, documented in the runbook (D7-3) | open | INFERRED design |
| 5.6 | **Super-user key without pod logs** — see below | open | VERIFIED problem |
| 5.7 | **Secrets (names and keys, proposed)**: `be293-identity-vault-unseal` (none in cluster if D7-3 = manual), `be293-issuerservice-vault-token`/`token`, `be293-identityhub-vault-token`/`token`, `be293-bdrs-vault-token`/`token`, `be293-issuerservice-superuser`/`api-key`, `be293-identityhub-superuser`/`api-key`, `be293-identity-postgres`/`postgres-password`,`issuerservice-password`,`identityhub-password`,`bdrs-password`; Portal side unchanged names: `be293-portal-identityhub`/`identityhub-api-key`,`issuerservice-admin-api-key`; `be293-portal-bdrs`/`management-api-key` (new values, scoped). BDRS Vault aliases: `edc.datasource.didentry.user`, `…password`, `mgmt-api-key` | proposal | INFERRED |
| 5.8 | **Issuer configuration**: issuer DID and key, BPN attestation per the proven DEV pattern (holder table keyed by `holder_id` = BPN, which is what the Portal sends, so the 2026-11-12 BPN NPE cannot occur), BPN definition `BpnCredential-id`, a **new** Membership definition with `memberOf` (DEV template invalid) | open | VERIFIED requirement (v5 §4.7) |
| 5.9 | **BDRS**: `server.trustedIssuers` = our issuer DID (template fails if empty); management API ClusterIP only (no Ingress) | open | VERIFIED (report item 8) |
| 5.10 | **NetworkPolicies (new, `be293`)**: default-deny stays; Portal → IdentityHub identity port, IssuerService admin port, BDRS 8081 (in-namespace selectors); IdentityHub ↔ IssuerService DCP via **public** hosts only if DID resolution forces it, otherwise in-cluster; each app → its PostgreSQL and the Vault 8200; nothing else reaches Vault; ingress-nginx → public endpoints only (DID, credentials, issuance, status list), never identity/admin/management ports; delete `be293-portal-release26-09-egress` in the switch step | open | INFERRED design |
| 5.11 | **Portal worker known defects** (v5 §4.7, Phase 4): deterministic `BuildHolderPid` (a retry after a terminal failure collides), no holder update on 409. Not blockers for the first clean onboarding; blockers for A5 (retry) | open | VERIFIED |
| 5.12 | **IdentityHub callback client** (`TX_PORTAL_CALLBACK_*`) in `centralidp-be293` with the issuer-callback roles, or confirmation that the Portal's own credential-await polling (`IdentityHubCredentialAwaitBusinessLogic`) suffices without the callback | open | INFERRED / NOT VERIFIED |

**5.6 Key handling without pod logs (proposal; extends v5 §4.9).**
1. **Preset, generated in-cluster.** A one-off approved Job generates the super-user bootstrap key
   (`base64(<superUserId>).<random>`, format per `SuperUserSeedExtension.java:93`) straight into Secret
   `be293-<app>-superuser`/`api-key`. It is never printed, never on a command line, never in Git or values. The app
   reads it through `envValueFrom` (`EDC_IH_API_SUPERUSER_KEY`; the IssuerService property name is still to verify).
2. **Rotate after seeding.** The seed Job (mounted Secret, `curl --config` from a memory `emptyDir`, no `set -x`) creates
   the issuer context and a dedicated Portal participant with the provisioner role, then calls
   **`regenerateParticipantToken`** for the super-user. That method exists in EDC IdentityHub 0.17.0
   (`participant-context-api-0.17.0.jar`, `ParticipantContextApiController.regenerateParticipantToken(String, SecurityContext)`).
   VERIFIED. Exact path `POST /v1alpha/participants/{id}/token`: INFERRED. Its presence in the IssuerService image:
   NOT VERIFIED. The new key goes straight into the Secret. The bootstrap key that `SuperUserSeedExtension` logged at
   INFO (`:103`) is then **invalid**.
3. **Scoped keys for the Portal.** IdentityHub: the Portal participant's own key (returned in the create response, not
   logged; not verified whether it is logged). IssuerService: the issuer context's key. Both written by the Job straight
   into `be293-portal-identityhub`. The Portal never holds a super-user key (v5 §3).
4. **RBAC.** The Job's Role has `get`/`update` on the named Secrets (`resourceNames`) only, and **no `pods/log`**.
5. **Defence in depth.** Treat the first-boot container log as sensitive until rotation is done. Acceptance checks
   that the bootstrap key returns 401 and that no current key value appears in any `be293` pod log (checked
   in-cluster by hash, never printed).

## 6. Proposed deployment order

Each step: target, server-side dry run, diff, explicit approval, then verification. Nothing in `release26-09` is touched
at any step.

| Step | What | Verification | Reversible because |
|---|---|---|---|
| 0 | P3-4 chart comparison (BDRS, IdentityHub chart); offline values, gates, tests; Secret contract; NetworkPolicies prepared | offline gates and tests green; no unexplained chart diff | nothing applied |
| 1 | NetworkPolicies for the identity stack (additive; the Portal policy unchanged) | `get networkpolicy`; Portal health unchanged | delete the new policies |
| 2 | **Vault** (Raft + PVC), init, unseal, KV v2, per-app policies and tokens; root token revoked | write/read a canary under a test path; **delete the pod → sealed → manual unseal → canary still there** | `helm uninstall` leaves the PVC; nothing depends on it yet |
| 3 | **PostgreSQL** for the identity stack | restart test with a canary table | nothing depends on it yet |
| 4 | **IssuerService**, bootstrap key preset, then the seed Job: issuer context, attestations, definitions, rotation | issuer DID document public over HTTPS; status list reachable; admin port not public; bootstrap key → 401 | uninstall; no holder exists yet |
| 5 | **IdentityHub** (+ callback extension per D7-2), bootstrap key, Portal provisioner participant, rotation | identity API reachable only in-cluster; a throwaway test participant created and **deleted**; DID host public; restart test (pods deleted, key and test DID survive) | uninstall; the Portal is not switched |
| 6 | **BDRS** (Postgres + Vault aliases, `trustedIssuers` = our issuer) | management API ClusterIP only; a test BPN→DID write/read/delete; restart test | uninstall; the Portal is not switched |
| 7 | **Portal endpoint switch** with a guarded wrapper like `switch-idp-be293.sh`: the `identityHub.*` and `bpnDidResolver.*` values and the Secret values; delete `be293-portal-release26-09-egress`; both CronJobs stay suspended | dry-run drift limited to the listed env vars; grep gate: no `release26-09` in the render; live env after upgrade | Helm rollback to revision 6 restores the old env; the deleted policy is re-applied from Git (both written down beforehand) |
| 8 | **Controlled onboarding test**: unsuspend the worker **only for this run**, one new test company (not `BPNL000000000EVQ`; D7-8), then suspend again | §7 acceptance | the test company is cleaned up with the Phase 11 runbook |

## 7. Acceptance tests

| # | Test | Expected | Evidence |
|---|---|---|---|
| P7-A1 | Participant-context creation | wallet step `DONE`; participant exists in **our** IdentityHub; holder DID `did:web:identityhub-be293…:<bpn>` resolves through `be293-did-resolver` | checklist state, IdentityHub GET, resolver |
| P7-A2 | Credential issuance | BPN and Membership credential `DONE`; `credentialSubject.id` = holder DID, `bpn` = BPN, issuer = our DID, signature valid, status list resolvable (v5 A2) | credential JSON, status list |
| P7-A3 | BPN→DID resolution | our BDRS returns the holder DID for the BPN; the shared BDRS has **no** new row (read-only GET on its directory before/after) | BDRS reads |
| P7-A4 | Full pod restart | delete every pod of Vault, both apps, BDRS, PostgreSQL; unseal; repeat A1 for a second company and re-read A2/A3 data | the same keys, DIDs, credentials and mappings |
| P7-A5 | Zero writes to `release26-09` | (a) rendered Portal config has no `release26-09` host and no `*.test.tractus-x.com` host of the shared identity stack; (b) `be293-portal-release26-09-egress` gone, no policy selects `release26-09`; (c) for public hosts sharing the ingress IP: configuration plus ingress/access logs show no request from `be293` to the shared IdentityHub/IssuerService/BDRS during the test | render grep gate, `get networkpolicy`, logs |
| P7-A6 | CronJobs | maintenance and worker `suspend: true` before and after (worker re-suspended after step 8) | `get cronjob` |
| P7-A7 | Key hygiene | bootstrap keys → 401; no current key value in any `be293` pod log (hash check in-cluster); no Role grants `pods/log` | §5.6 |
| P7-A8 | Exposure | identity, admin and management ports unreachable from outside the cluster; DID, credentials, issuance and status list reachable | external curl |

## 8. Remaining shared dependencies and risks

| Item | Risk | Class |
|---|---|---|
| BPDM Gate/Pool + `sa-cl7-cx-5` on the shared CentralIDP | unchanged by design (G1-1); rotation of that client breaks the BPN step | VERIFIED (accepted) |
| **`BPNACCESS__BASEADDRESS` (registration service)** | the BPN lookup **forwards the user's own token** (`BpnAccess.cs:33-36`, `RegistrationBusinessLogic.cs:80`), now issued by `centralidp-be293`. If the public Pool only trusts the shared issuer, the registration form's BPN lookup fails (401). Already in effect since revision 6. **NOT VERIFIED.** Check: one registration-form BPN lookup, or the registration-service log for a 401 from `…/pool/v6/legal-entities` | NOT VERIFIED |
| Frontend BPDM/semantics calls with the user's token | same question | INFERRED |
| Credentials trusted only inside BE-293 | connectors in `connector`/`release26-09` and the shared BDRS do not know our issuer or our DIDs (accepted limit, v5 §2) | VERIFIED (accepted) |
| BDRS directory readers (services, administration, marketplace, frontend) | if they stay on the shared directory they will not see our BPN→DID rows (D7-6) | VERIFIED |
| Vault unseal | after any Vault restart the stack is down until a human unseals; node events at night mean downtime | INFERRED |
| `BPNL000000000EVQ` in our Portal DB | its application stopped at the wallet step against the shared IdentityHub; a holder may or may not exist **there** (on a 500, INFERRED not). It must not be resumed against the new stack without a decision (D7-8) | INFERRED |
| Chart provenance (BDRS, IdentityHub v0.3.2) | unexplained local changes (§4.5) | VERIFIED gap |
| Worker defects (holder PID, 409) | retries after a terminal failure collide (§5.11) | VERIFIED |
| DNS / ExternalDNS (D2) | new public names may not appear; Let's Encrypt rate limits | NOT VERIFIED |

**Rollback requirements per step** (in addition to §6): before each step record the Helm revision, rendered
manifest, Secret **names** and the NetworkPolicy set. Keep every PVC (`Retain`; `helm uninstall` never deletes
StatefulSet PVCs). For step 7, pre-write the revision-6 rollback command and the exact policy YAML to re-apply. No
rollback may touch `release26-09`.

## 9. Exact files that would need changing (not changed)

**New** (under `alpha/portal-release-prepared/` unless stated):
- `values-be293-identity-vault.yaml`, `values-be293-identity-postgres.yaml`, `values-be293-issuerservice.yaml`,
  `values-be293-identityhub.yaml`, `values-be293-bdrs.yaml` — per-release values (Raft, PVCs, `envValueFrom`, no dev Vault,
  no root token, ClusterIP for admin/management, Ingress for public endpoints only).
- `networkpolicies-be293-identity.alpha.yaml` — §5.10.
- `tools/identity-seed-be293.sh` plus its Job manifest — §5.6 (no `pods/log`), issuer attestations and definitions.
- `tools/switch-identity-be293.sh` and `expected-drift.identity-switch.alpha.yaml` — step 7 wrapper modelled on
  `switch-idp-be293.sh`.
- `tools/validate_identity.rb` plus `tests/test_validate_identity.rb`, `tests/test_identity_seed.rb`,
  `tests/test_switch_identity_wrapper.rb`.
- Chart pins: the identity charts as sha256-pinned packages (location per D7-2), plus the P3-4 comparison appendix in
  `docs/dev/BE-293-phase1-discovery-report.md`.

**Changed:**
- `values-be293-portal.yaml`: `identityHub.baseAddress`, `credentialServiceBaseAddress`, `didDocumentBaseLocation`,
  `issuerDid`, `issuerParticipantId`, `issuerAdminBaseAddress`, `bpnCredentialDefinitionId`/`membershipCredentialDefinitionId`
  (if renamed), administration `issuerdid`, `bpnDidResolver.managementApiAddress` (and `directoryApiAddress` per D7-6),
  `sdfactoryAddress` (per D7-9).
- `networkpolicies-be293-portal.alpha-release.yaml`: remove `be293-portal-release26-09-egress`; add in-namespace egress
  to the identity Services.
- `secrets-contract.yaml`: new identity Secrets; `be293-portal-identityhub` and `be293-portal-bdrs` reclassified from
  "owner-provisioned (release26-09)" to "seed-job-provisioned (be293)".
- `alpha-service-map.yaml`: add the `be293` identity Services, drop the `release26-09` identity entries.
- `images.lock.yaml`: identity images by digest.
- `expected-inventory.alpha-release.txt` (if the Portal render changes inventory) and a new identity inventory file.
- `tools/render-release.sh` / `tools/validate_render.rb`: add the identity gates and a "no `release26-09`" grep gate.
- `docs/dev/BE-293-alpha-portal-test-replica-roadmap-v5.md` → v6: Phase 7 as executed.

## 10. Decisions requiring your approval

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D7-1 | Release structure | (a) `identity-and-trust-bundle` as-is; (b) four discrete releases + PostgreSQL | **(b)**: independent rollback, no dev-Vault defaults, matches the Keycloak approach |
| D7-2 | IdentityHub/IssuerService chart + image | (a) pinned v0.3.2 charts + official images; (b) charts v0.4.2 (as in `release26-09`) + official 0.4.1 images; (c) (b) + our fork images (callback extension) moved to Harbor by digest | **(c) if the callback is required, else (b)**; decide after D7-10. Not (a): provenance gap and an older line than the Portal client targets |
| D7-3 | Vault unseal | (a) manual Shamir unseal by the operator; (b) unseal key in a K8s Secret with an unseal Job | **(a)**: (b) puts the unseal key next to the data it protects. Accept downtime until unsealed and document it |
| D7-4 | Vault and PostgreSQL topology | (a) one Vault + one PostgreSQL for the stack, separate paths/policies and databases/users; (b) one per app (BDRS pattern) | **(a)**: one unseal, one backup; isolation by policy and DB user |
| D7-5 | Super-user key handling | (a) preset + rotate via `regenerateParticipantToken` (§5.6); (b) preset + suppress the INFO line by log level only | **(a)**, with (b) as defence in depth |
| D7-6 | BDRS directory readers | (a) repoint the four directory settings to our BDRS (needs a public directory Ingress); (b) leave them on the shared directory | **(a)**: otherwise the Portal does not see its own mappings. Reads only, so either way the read-only rule holds |
| D7-7 | Public hostnames | `identityhub-be293`, `issuer-be293` (and `bdrs-be293` if D7-6a) under `test.tractus-x.com` via ExternalDNS | approve the names; verify D2 first |
| D7-8 | `BPNL000000000EVQ` | (a) leave its application as is and onboard a fresh test company; (b) retry it against the new stack | **(a)** first; decide (b) after A1–A4 pass |
| D7-9 | SD Factory address | (a) keep `sdfactory.release26-09…` (inactive); (b) `https://sdfactory.disabled.invalid` | **(b)**: removes the last configured `release26-09` write target |
| D7-10 | IdentityHub → Portal callback | (a) deploy the callback extension with a client in `centralidp-be293`; (b) rely on the Portal's credential-await polling | verify first which one the `e2451f876` worker uses; then pick the minimum |
| D7-11 | Diagnose the current 500 | (a) run the read-only log commands in §3.4; (b) also the single authenticated GET | **(a)** now; (b) only if (a) is inconclusive |
| D7-12 | Membership credential definition | content of `memberOf` (and whether `arena-x`, cf. report Addendum A W4) | your call; the DEV template is not valid |

**STOP.** Nothing beyond this report was written. Waiting for approval.
