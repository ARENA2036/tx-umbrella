# BE-293 Alpha — Phase 1 discovery report (offline pass)

**Date:** 2026-11-16
**Roadmap:** `docs/dev/BE-293-alpha-portal-test-replica-roadmap-v4.md`, §6 Phase 1, items 1–10
**Gate state:** Gate 0 NOT PASSED. **Gate 1 PASSED 2026-11-16 (Payam), with two caveats**, both closed or
carried forward in this revision:
1. *Approximate citations.* Three evidence ranges in item 5 were wider than the lines read. **Corrected
   2026-11-16** against `e2451f876`.
2. *Unverified chart provenance.* The `9e4524fb…` centralidp copy is only inferred to be upstream, and the
   pinned `bdrs-server-0.6.0.tgz` differs from the published digest without a content comparison. **Carried
   into Phase 3** of roadmap v5 (BDRS chart comparison).

**Revision 2026-11-16:** corrected citations: three ranges in item 5, plus two off-by-one `appsettings.json` lines in item 2 (`Apps.Service` `:147`, `Services.Service` `:144`) found during the audit. Added Addendum A, the audit of commit `43767079b`.
**Mode:** offline only. The Alpha kubeconfig token is expired, so **no cluster read was made**. Every item
that needs the cluster is marked **PENDING – NO CLUSTER ACCESS**.

Nothing in §4 of the roadmap was re-investigated. D1 and BDRS are treated as decided. Where a finding here
touches a decided item, it is recorded as an implementation consequence or a question, not as a reopening.

## What was read

| Source | Revision |
|---|---|
| `tx-umbrella` (this repo) | branch `feat/BE-293-alpha-release-package` @ `334ef7d` |
| Pinned charts `handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/{centralidp,sharedidp}-4.2.1.tgz`, `portal-2.6.0.tgz`, `bdrs-server-0.6.0.tgz` | Git-tracked; extracted read-only to a scratch directory outside the repo |
| `portal-backend-await-fix` | `e2451f876` (clean worktree; = commit of the deployed Worker image per `images.lock.yaml`) |
| `~/Backup/Projects/public-tractus-x-umbrella` (DEV blueprint) | `a5b07c5`, reference only |
| `~/Backup/Projects/public-tractusx-identityhub-be293` | `3633af6`, reference only |
| `tx-umbrella-0.13-integration/recovery/be293-dev-3.17.0/VALIDATION.md` | chart provenance record |

Chart file references below are written as `<chart>.tgz!templates/<file>:<line>`, meaning a path inside the
pinned, Git-tracked package.

No secret value was read, printed or copied. Values files were read with secret-bearing keys redacted.

---

## Summary — the two priority items

| Item | Answer | Status |
|---|---|---|
| **2 — `arena` client scope** | The stock seed does **not** create `arena`; it creates `catena`. `arena` comes from a bulk "catena → arena" rename in Portal commit `43767079b` ("chore:ARENA branding"), which is in every deployed image. It affects **app/service client creation only** (marketplace offers), **not** invitation, onboarding or activation. A hand-added scope would be **deleted by the next seed run** (`DELETE=true`). | CONFIRMED (source); Keycloak's reaction to the unknown scope is INFERRED |
| **5 — cleanup on failed invitation** | **Nothing triggers the `DELETE_*` chain on a failed invitation.** The chain is created only by an applicant-initiated decline. Worse: the Portal writes its `identity_providers` / `iam_identity_providers` rows only at **step 9 of 10**, so a failure in steps 1–8 leaves Keycloak objects that **no deletion path can find**. | CONFIRMED (source) |

Two further findings were not asked for but change Phase 3 work. They are recorded here as consequences, not as
re-opened decisions:

- **Appendix A:** the Portal chart builds the BPDM token endpoint (and four other token endpoints) from
  the single value `centralidp.address`. Implementing D1 (a) therefore needs a chart patch. Changing
  `centralidp.address` alone would also move BPDM to our IdP. See item 3.
- **BDRS repoint touches more than two settings.** Four further settings and one NetworkPolicy reference the
  shared BDRS. See item 8.

---

## Item 1 — Realm-seeding jobs (centralidp, sharedidp)

**Finding:**

*Mechanism.* Both charts run the Portal's `Keycloak.Seeding` app (`tractusx/portal-iam-seeding:v4.2.0-iam`).
The realm JSON is **not in the chart**. An init container copies it from an image:
- centralidp: `cp -R /import/catenax-central/realms/* /app/realms`
- sharedidp: `cp -R /import/catenax-shared/realms/* /app/realms`

The chart default image is `tractusx/portal-iam:v4.2.0`. The **umbrella overrides centralidp's** image with
`tractusx/umbrella-init-container:2.3.0-init`, which this repo builds from `init-container/`. So the CX-Central
seed the umbrella uses is `init-container/iam/centralidp/CX-Central-realm.json` (inferred: assuming tag
2.3.0 matches the current directory content). sharedidp keeps the stock image. **No local copy of
`CX-Operator-realm.json` or `master-realm.json` exists.**

*Re-runs.* The Job is named `…-realm-seeding-<revision>`, so **every Helm upgrade runs the seed again**.
Both main realms run with `CREATE=UPDATE=DELETE=true`. With `DELETE=true`, the seeder **deletes every client
scope in the realm that is not in the seed JSON** (see item 2). It does **not** delete top-level clients or
identity providers that the Portal created. It only reconciles mappers, scopes and federated identities on
objects that are in the seed.

*CX-Central (centralidp)*, from the umbrella seed JSON plus chart env:

| Aspect | Value |
|---|---|
| Realm | `CX-Central` (only realm seeded; master untouched) |
| Clients | 53 total, 35 with service accounts |
| Browser/app clients | `Cl1-CX-Registration`, `Cl2-CX-Portal`, `Cl3-CX-Semantic`, `Cl5-CX-Custodian`, `Cl7-CX-BPDM`, `Cl16-CX-BPDMGate`, `Cl21-CX-DF`, `Cl22-CX-BPND`, `Cl23-CX-Policy-Hub`, `Cl24-CX-SSI-CredentialIssuer`, `Cl25-CX-BPDM-Orchestrator`, `technical_roles_management` |
| Base service accounts | `sa-cl1-reg-2`, `sa-cl2-01…06`, `sa-cl3-cx-1`, `sa-cl5-custodian-2`, `sa-cl7-cx-1`, `sa-cl7-cx-5`, `sa-cl7-cx-7`, `sa-cl8-cx-1`, `sa-cl21-01`, `sa-cl22-01`, `sa-cl24-01`, `sa-cl25-cx-1…3` (19) |
| **Test service accounts** | `satest01…satest16` are **in the umbrella's realm JSON** (umbrella test data) |
| Roles | 4 realm roles; client roles on 53 clients |
| Identity providers | `CX-Operator` only (→ sharedidp `CX-Operator` realm; URLs from `realmSeeding.sharedidp`) |
| Operator user | `ac1cf001-7fbc-1f2f-817f-bce058020006`, attribute `bpn = realmSeeding.bpn` (default `BPNL00000003CRHK`), no credential (federated via CX-Operator) |
| Redirects / root URL | env from `realmSeeding.clients.{registration,portal,semantics,miw,bpdm,bpdmGate}.redirects`, `clients.portal.rootUrl` |
| Web origins | `+` in the JSON for the Portal clients (follows redirects); not value-controlled |
| `frontendUrl` | **not set** in the seed → issuer depends entirely on Keycloak hostname/proxy config (roadmap §4.5) |
| SMTP | **none** in CX-Central |
| Password policy | **none** (`passwordPolicy` absent) |
| `sslRequired` | JSON says `none`; overridden by env `realmSeeding.sslRequired` (chart default `external`, umbrella values `none`) |
| `duplicateEmailsAllowed` | `true` |
| Seeding resources | 850M request = limit |

*sharedidp*, from chart env only (JSON not inspectable offline):

| Aspect | Value |
|---|---|
| Realm 0 | `CX-Operator`, `CREATE/UPDATE/DELETE=true` |
| Client | `central-idp`, redirect `<centralidp>/auth/realms/CX-Central/broker/CX-Operator/endpoint/*`, `jwks.url` → CX-Central certs |
| Initial user | ID `656e8a94-188b-4a3e-9eec-b45d8efd8347`; username, names, e-mail and password **from Secret keys** `initial-user-*`. Values comment: default password `"!3changemeTractus-X"` if not set → **A14 relevance** |
| SMTP | `CX-Operator` realm only, all six fields from Secret keys `mailing-*` |
| Realm 1 | `master`, global `CREATE/UPDATE/DELETE=false`; only clients `sa-cl1-reg-1` (Portal provisioning, = `Keycloak:shared` client) and `saCX-Operator` may be created/updated/deleted |
| Partner realms | not seeded; created by the Portal invitation; their SMTP comes from Portal `PROVISIONING__SHAREDREALM__SMTPSERVER__*` (D5) |
| Seeding resources | 700M request = limit |

**Evidence:**
- `centralidp-4.2.1.tgz!values.yaml:144-266`, `sharedidp-4.2.1.tgz!values.yaml:152-219`
- `centralidp-4.2.1.tgz!templates/job-seeding.yaml:29` (Job name per revision), `:82` (`DELETE=true`), `:88`, `:271` (init copy)
- `sharedidp-4.2.1.tgz!templates/job-seeding.yaml:87`, `:100-149` (client + initial user), `:155-184` (SMTP keys), `:190-235` (master realm config), `:301`
- `handoff/BE-293-umbrella-3.17.0/chart/umbrella/values.yaml` centralidp `initContainer.image.name: docker.io/tractusx/umbrella-init-container:2.3.0-init`
- `init-container/Dockerfile` — `COPY iam/centralidp/ import/catenax-central/realms`
- `init-container/iam/centralidp/CX-Central-realm.json:30` (`sslRequired: none`), `:10138` (default scopes); parsed with a read-only script (client, scope, role and user lists above; secrets not read)
- `portal-backend-await-fix/src/keycloak/Keycloak.Seeding/BusinessLogic/ClientScopesUpdater.cs:42,52-61`; `ClientsUpdater.cs:59-68` (clients: create/update only); `IdentityProvidersUpdater.cs:48-56,113-122` (IdPs: mappers only)
- Search: `find ~/Projects/ARENA2036 ~/Backup/Projects -name '*realm*.json'` → only `CX-Central-realm.json` copies (all identical, sha256 `a37ce7b652ee…`, except the DEV backup `7ee9f067d73b…`)

**Status:** CONFIRMED for the chart and the umbrella CX-Central JSON. INFERRED: that `umbrella-init-container:2.3.0-init`
equals the current `init-container/` content; that the seeder in image `v4.2.0-iam` behaves like the fork
source read here. **PENDING – NO CLUSTER ACCESS / NO IMAGE PULL:** the content of `CX-Operator-realm.json` and
`master-realm.json` (password policy, CX-Operator clients) — needs `tractusx/portal-iam:v4.2.0` image contents.

**Consequence for the roadmap:**
- Phase 3 must choose the CX-Central seed source. The umbrella image brings 16 `satest*` service accounts.
  Their secrets are generated by the chart unless supplied, and they are test data with BPNs. The stock image
  probably does not include them (inferred). **Question for Payam.**
- Anything we add to CX-Central must be **in the seed**, not added by hand (because of `DELETE=true`).
- `frontendUrl` is not seeded, so the A9 issuer assertion depends only on the proxy-header config (§4.5).

---

## Item 2 — The `arena` client scope  ★ priority

**Finding:**

1. **Origin.** Upstream used `catena`. Commit `43767079b` ("chore:ARENA branding", 2026-07-10) replaced
   `"catena"` with `"arena"` in `Provisioning:CentralOIDCClient:defaultClientScopes` in three
   `appsettings.json` files. It was a bulk text rename. The same commit also renamed three other wire
   identifiers (below). One of them was already found and fixed in `e2451f876`.
2. **Deployed?** Yes. All three image source commits contain `arena` and no `catena` in all three files:
   `274096a96` (administration), `ad459ee71` (registration, marketplace, services…), and `e2451f876` (worker).
   The Portal chart has no env hook for this setting, so the baked value is the live value.
3. **Stock seed.** CX-Central has client scopes `address, profile, catena, offline_access, email, phone,
   role_list, roles, basic, microprofile-jwt, acr, web-origins`. **No `arena`.** The same holds for every
   local copy of the realm JSON. `catena` carries three mappers: `organisation`, `preferred_username` and
   `bpn`.
4. **Who uses `CentralOIDCClient`.** Only `ProvisioningManager.SetupClientAsync`. It is called only from
   `OfferSetupService.CreateClient`, which serves app/service **offer** autosetup, single-instance app setup,
   and the `OfferSubscription` process `CREATE_CLIENT` step. **Invitation, registration, the application
   checklist and `APPLICATION_ACTIVATION` do not create OIDC clients.** The roadmap's wording ("when the
   Portal creates a company's OIDC client") is imprecise. This path is not part of the Phase 9 definition of
   done. It is reached when a provider releases or subscribes an app or service.
5. **What Keycloak does with the unknown scope.** Not verifiable offline: no Keycloak source is available
   locally. INFERRED from Keycloak behaviour: client creation via the admin REST API **ignores unknown default
   scope names** and logs only at debug level. If so, the failure is **silent**. The client gets created
   without the `bpn` and `organisation` claims, and apps that rely on those claims break later. The roadmap's
   two hypotheses ("someone added it for us" or "client creation has been failing") have a third
   alternative: **it has never mattered because it was silently dropped.**
6. **A manual fix will not hold.** CX-Central seeds with `DELETE=true`, and `RemoveObsoleteClientScopes`
   deletes every scope that is not in the seed JSON, on every Helm revision. A hand-added `arena` scope
   disappears on the next upgrade.

Other identifiers changed by the same commit (same defect class; listed so they are not found late). The
complete audit of the commit is **Addendum A**.

| Identifier | Now | Was | State |
|---|---|---|---|
| BPDM `BpdmCxMembershipDto` JSON | `isCatenaXMember` | — | **fixed** in `e2451f876` |
| BPDM `BpdmLegalEntityDto` JSON | `isArenaXMemberData` | `isCatenaXMemberData` | still renamed. BPDM is out of scope (§2.1 C). Recorded only. |
| Membership `memberOf` literal | `"arena-x"` | `"catena-x"` | passed in `CreateMembershipCredentialRequest`, but **not used** by the IdentityHub path (item 7). Relevant to D6. |
| `AppsSettings` / `ServiceSettings` | `ArenaAdminRoles` | `CatenaAdminRoles` | the chart sets neither name, so there is no change in behaviour |

**Evidence:**
- `portal-backend-await-fix/src/processes/Processes.Worker/appsettings.json:273-279`, `src/marketplace/Apps.Service/appsettings.json:147`, `src/marketplace/Services.Service/appsettings.json:144`
- `git show 43767079b -- '*appsettings*.json'` → `-        "catena",` / `+        "arena",` (3×)
- `git show <commit>:<file> | grep -c '"arena"'` = 1 and `'"catena"'` = 0 for `274096a96`, `ad459ee71`, `e2451f876` × 3 files
- `~/Backup/Projects/public-portal-backend` `src/processes/Processes.Worker/appsettings.json:273-274` → `"catena"`
- `src/provisioning/Provisioning.Library/Extensions/ClientManager.cs:110-121` (clone of `CentralOIDCClient`, POST to `CentralRealm`); `src/keycloak/Keycloak.Library/Models/Clients/Client.cs:88` (`DefaultClientScopes` serialised)
- `src/provisioning/Provisioning.Library/ProvisioningManager.cs:84-88`; `src/marketplace/Offers.Library/Service/OfferSetupService.cs:102,175,292-300,481` — the only callers
- `init-container/iam/centralidp/CX-Central-realm.json:9788` (`catena` scope); parsed scope list above
- `portal-2.6.0.tgz!templates/*` — `grep -i 'clientscope\|CENTRALOIDC'` → no match
- `src/keycloak/Keycloak.Seeding/BusinessLogic/ClientScopesUpdater.cs:52-61` + `centralidp-4.2.1.tgz!templates/job-seeding.yaml:82`

**Status:** CONFIRMED for items 1–4 and 6. INFERRED for item 5 (Keycloak behaviour).
**PENDING – NO CLUSTER ACCESS:** whether the shared CX-Central has an `arena` scope (read-only `GET` on his
Keycloak, or ask Saud — the optional D3 question). Also whether any `iam_clients` rows exist in our Portal
DB, which would show whether an offer client was ever created.

**Consequence for the roadmap:** resolve before writing any values file (as §4.5 says), but this is **not a
Phase 9 blocker for login/onboarding**. **Decision for Payam** — pick one:
- (a) Add an `arena` client scope (same mappers as `catena`) to **our** CX-Central seed. This means a
  BE-293 init-container variant, since the scope has to live in the seed.
- (b) Restore `catena` in the three `appsettings.json` files. This needs an image rebuild of administration,
  marketplace, services and worker, or a chart patch adding an env override.

Option (b) also removes an ARENA-specific divergence from upstream. Either way, the Phase 10 acceptance needs
a test that creates an offer client and asserts the `bpn` claim in its token.

---

## Item 3 — Appendix A: Portal IDP configuration surface

**Finding:** the backend code resolves each token endpoint per integration (§4.1, D1). **The chart does
not.** It derives these settings from the single value `centralidp.address` plus a path:

| Setting (env) | Components | Template expression |
|---|---|---|
| `APPLICATIONCHECKLIST__BPDM__TOKENADDRESS` | worker, administration | `centralidp.address + backend.keycloak.central.tokenPath` |
| `APPLICATIONCHECKLIST__SDFACTORY__TOKENADDRESS` | worker, administration | same |
| `APPLICATIONCHECKLIST__CUSTODIAN__TOKENADDRESS` | worker, administration | same |
| `APPLICATIONCHECKLIST__ISSUERCOMPONENT__TOKENADDRESS` | worker, administration | same |
| `APPLICATIONCHECKLIST__DIM__TOKENADDRESS` | administration | same (worker uses `dimWrapper.tokenAddress`) |
| `OFFERPROVIDER__TOKENADDRESS` | worker | same |
| `SERVICEACCOUNT__AUTHSERVICEURL` | administration | same |
| `JWTBEAREROPTIONS__METADATAADDRESS`, `…__VALIDISSUER` | administration, registration, appmarketplace, services, notification | `centralidp.address + jwtBearerOptions.*Path` |
| `KEYCLOAK__CENTRAL__CONNECTIONSTRING`, `KEYCLOAK__CENTRAL__AUTHREALM`, `PROVISIONING__CENTRALREALM` | same five + worker | `centralidp.address`, `centralidp.realm` |
| `KEYCLOAK__SHARED__CONNECTIONSTRING` | same five + worker | `sharedidpAddress` |
| `CENTRALIDP_URL`, `REALM`, `CLIENT_ID*` | frontend portal, frontend registration | `centralidp.address + frontend.centralidpAuthPath`, `centralidp.realm`, `centralidp.clients.*` |

**Consequence:** if `centralidp.address` is pointed at ours, then BPDM, SD Factory, Custodian, Issuer
Component and OfferProvider tokens are requested **from our** CentralIDP. BPDM would then fail, because
`sa-cl7-cx-5` exists only in the shared realm and the testbed trusts only the shared issuer. **D1 (a) stays
correct at the code level, but implementing it needs a patch to the (already forked) Portal chart.** The
patch must give `APPLICATIONCHECKLIST__BPDM__TOKENADDRESS` its own value. That is Phase 3 work.

Filled table:

| Area | What | Current (prepared values) | Target | Evidence |
|---|---|---|---|---|
| Portal values | CentralIDP address | `https://centralidp.test.tractus-x.com` | `https://centralidp-be293.test.tractus-x.com` | `values-be293-portal.yaml:19-20` |
| Portal values | SharedIDP address | `https://sharedidp.test.tractus-x.com` | `https://sharedidp-be293.test.tractus-x.com` | `values-be293-portal.yaml:21` |
| Frontend | authority, realm, client id | `centralidp.address` + `/auth`; `CX-Central`; `Cl2-CX-Portal` / `Cl1-CX-Registration` (chart defaults) | our host; same realm/client IDs if the stock seed is used | `portal-2.6.0.tgz!templates/deployment-frontend-portal.yaml:65-91`, `deployment-frontend-registration.yaml:61-65`; `values.yaml:27-35,239` |
| Frontend | redirect URIs / web origins | set in the **centralidp seed**, not the Portal: `realmSeeding.clients.portal.{rootUrl,redirects}`, `registration.redirects`; web origins `+` | `https://portal-be293.test.tractus-x.com/*` (+ registration host) | item 1 |
| Backend (5 services) | JWT metadata address | derived: `centralidp.address` + `/auth/realms/CX-Central/.well-known/openid-configuration` | follows `centralidp.address` | `portal-2.6.0.tgz!values.yaml:318-320`; `deployment-backend-administration.yaml:369-370` |
| Backend (5 services) | valid issuer / audience | derived `…/auth/realms/CX-Central`; audiences `Cl2-CX-Portal`, `Cl1-CX-Registration` | follows; **must equal the `iss` in a real token** (A9) | `values.yaml:321-324`; `deployment-backend-administration.yaml:375-376` |
| Backend | `Keycloak:central` | `centralidp.address`, realm `CX-Central` (auth realm), client `sa-cl1-reg-2`, secret `be293-portal-keycloak/central-client-secret` | our host, new secret | `values-be293-portal.yaml:92-97`; `secrets-contract.yaml:30` |
| Backend | `Keycloak:shared` | `sharedidpAddress`, client `sa-cl1-reg-1` (master), secret `be293-portal-keycloak/shared-client-secret` | our host, new secret | `values-be293-portal.yaml:98-100`; `secrets-contract.yaml:31` |
| Registration / Administration | IdP alias prefix | not in values; alias from `GetNextCentralIdentityProviderNameAsync` (`be293-alpha-idp-N` observed, §1) | unchanged | `Invitation.Executor/InvitationProcessService.cs:79` |
| Processes worker | IDP settings | same derived set as above + `PROVISIONING__CENTRALREALM` | follows | `cronjob-backend-processes.yaml:146-147,242-243,307-308,510-511` |
| **Outbound: BPDM** | token endpoint, client, secret | **derived from `centralidp.address`**; `sa-cl7-cx-5`; `be293-portal-interfaces/bpdm-client-secret` | **shared, unchanged (D1a) — needs chart patch** | `cronjob-backend-processes.yaml:146-147`; `deployment-backend-administration.yaml:120-121`; `values-be293-portal.yaml:196-198`; `secrets-contract.yaml:35` |
| Outbound: SD Factory | token endpoint, client | derived from `centralidp.address`; `sa-cl8-cx-1`; service in `release26-09` | see note ¹ | `cronjob-backend-processes.yaml:242-243`; `values-be293-portal.yaml:42,199-201` |
| Outbound: Clearing House / DIM / Custodian | token endpoint | `*.disabled.invalid` (DIM/CH); Custodian derived from `centralidp.address` but `custodianAddress` disabled | none | `values-be293-portal.yaml:52-62` |
| **BDRS** | management address, API key | `http://bdrs-server.release26-09.svc.cluster.local:8081`; `be293-portal-bdrs/management-api-key` | own BDRS in `be293` | `values-be293-portal.yaml:44-48`; see item 8 for the other four references |
| IdentityHub / IssuerService | `APPLICATIONCHECKLIST__IDENTITYHUB__*` | `identity-hub-01.release26-09…:8082`, issuer `…release26-09…:8086`, `issuerDid did:web:issuer-service.test.tractus-x.com:BPNL00000003CRHK`, `issuerParticipantId: issuer` | own stack | `values-be293-portal.yaml:205-228` |
| Administration | `issuerdid` | `did:web:issuer-service.test.tractus-x.com:BPNL00000003CRHK` | our issuer DID | `values-be293-portal.yaml:127` (also a shared-stack reference) |
| Kubernetes Secrets | keys holding IdP client secrets | `be293-portal-keycloak`: `central-client-secret`, `shared-client-secret`; `be293-portal-interfaces`: `bpdm-client-secret`, `sdfactory-client-secret` | central/shared: new; bpdm: unchanged | `secrets-contract.yaml:27-36` (names only) |
| NetworkPolicy | egress to Keycloak / `release26-09` | `be293-portal-release26-09-egress` (4 rules, incl. BDRS 8081); Keycloak only via `be293-portal-public-egress` → `ipBlock 188.34.116.149/32:443` | see note ² | `networkpolicies-be293-portal.alpha-release.yaml:98-145,167-180` |

¹ With `clearinghouse.default.clearinghouseConnectDisabled: true`, the LP self-description step returns
`SKIPPED` without calling SD Factory (`SdFactory.Library/BusinessLogic/SdFactoryBusinessLogic.cs:66-80`). So
SD Factory is not called in the onboarding flow as configured. The token endpoint still derives from
`centralidp.address`. INFERRED: no regional clearinghouse override exists (none in the overlays).

² Our new Keycloak hosts will most likely sit behind the same shared ingress address as the shared
Keycloak. If so, the `/32` rule **cannot tell "our Keycloak" from "his Keycloak"**, and A12 cannot be proven
from NetworkPolicy for Keycloak traffic. The proof would have to come from configuration plus traffic
evidence. INFERRED; depends on the ingress IP of our Ingresses.

**Status:** CONFIRMED (chart + values). PENDING – NO CLUSTER ACCESS: the live env of the deployments and the
CronJob (kit item 10 `jq` commands), which would confirm that the rendered release matches these values.

---

## Item 4 — Full `portal` schema dump

**PENDING – NO CLUSTER ACCESS.** Kit 12b also needs explicit approval (`pods/exec`).

Offline input for D4 from item 5: `company_invitations.idp_name` is the **only** Portal record of an alias
whose invitation failed before step 9. A clean re-seed (D4 recommendation) loses that record. **Run the
orphan query below before any re-seed.** It is the inventory Saud needs for §4.4 and Phase 11:

```sql
-- read-only; aliases created in Keycloak but never registered as a Portal IdP
select ci.idp_name, ci.date_created
from portal.company_invitations ci
left join portal.iam_identity_providers iip on iip.iam_idp_alias = ci.idp_name
where ci.idp_name is not null and iip.iam_idp_alias is null;
```

(Column names follow the entity `CompanyInvitation.IdpName` and the §4.6 table names. Verify against the
catalogue first, per kit 12b. This has not been run.)

---

## Item 5 — Does anything trigger `DELETE_*_IDENTITY_PROVIDER` on a failed invitation?  ★ priority

**Finding: No.**

*How the invitation runs.* Ten steps, in this order:
1. `CREATE_CENTRAL_IDP` — Keycloak: IdP in CX-Central. Also writes `company_invitations.idp_name`.
2. `CREATE_SHARED_IDP_SERVICE_ACCOUNT` — Keycloak (sharedidp master).
3. `ADD_REALM_ROLE`
4. `CREATE_SHARED_REALM` — Keycloak: realm in sharedidp.
5. `CREATE_CENTRAL_IDP_ORG_MAPPER`
6. `UPDATE_CENTRAL_IDP_URLS`
7. `CREATE_SHARED_CLIENT`
8. `ENABLE_CENTRAL_IDP`
9. `CREATE_DATABASE_IDP` — **first time** the Portal writes `identity_providers`, `company_identity_providers` and `iam_identity_providers`.
10. `CREATE_USER`

*On failure.* `InvitationProcessTypeExecutor` handles errors like this: a recoverable error sets the step
back to `TODO`. Anything else sets it to `FAILED` and schedules **only** `RETRIGGER_INVITATION_<step>`, a
manual operator retrigger. There is no compensation step.

*Who creates the deletion chain.* The `IDENTITYPROVIDER_PROVISIONING` process (`DELETE_IDP_SHARED_REALM` →
`DELETE_IDP_SHARED_SERVICEACCOUNT` → `DELETE_CENTRAL_IDENTITY_PROVIDER` → `DELETE_IDENTITY_PROVIDER`) is
created in exactly **one** place: `Registration.Service` `DeclineApplicationRegistrationAsync`. The applicant
calls it through `POST /api/registration/applications/{id}/declineregistration`. It requires:
- a logged-in applicant user, so step 10 must have succeeded;
- a valid company;
- application status in `ApplicationDeclineStatusIds` (chart default `CREATED…VERIFY`).

Two other paths delete IdPs **synchronously** (not via the chain). Both read the IdP from Portal DB rows:
- Operator decline `DeclineRegistrationVerification`. Requires status **`SUBMITTED`** and the
  `REGISTRATION_VERIFICATION` checklist entry.
- Company-admin `DeleteCompanyIdentityProviderAsync`. Requires ownership, a **disabled** IdP, and another
  active IdP for every linked company.

| Failure point | Keycloak objects left | Portal DB rows | Any cleanup path? |
|---|---|---|---|
| Steps 1–8 | central IdP (+ shared SA, shared realm, client, … depending on step) | **none** (only `company_invitations.idp_name`) | **None.** No path can find them. Manual Keycloak cleanup only. |
| Step 9 → 10 (`CREATE_USER` fails) | all | IdP rows exist; no applicant user | Not by applicant (cannot log in). Not by operator (not `SUBMITTED`). Admin delete needs a disabled IdP plus another IdP. **Effectively none.** |
| Invitation done, application never submitted | all | all | Only if the applicant clicks "decline". |
| Submitted, then a checklist step fails (e.g. `be293-alpha-idp-3`, failed before BPN) | all | all | Only an operator manual decline. Nothing automatic. |

So `be293-alpha-idp-3` is not a "half-created" invitation. It is a complete invitation whose application
stalled later, and nobody declined it. (Inferred from §4.4: it has an IdP row and a company, but no BPN.)

*Small additional risk (inferred).* Step 1 creates the Keycloak IdP **before** the Portal saves `idp_name`.
If the save fails after a successful Keycloak call, the retrigger creates a **new** alias. The first one is
then orphaned with no Portal record at all.

Re-check of §4.4 wording: "creates the identity provider, the company link and the IAM alias early … long
before BPN assignment". True relative to BPN assignment. Within the invitation, the DB rows come **last**
(`InvitationProcessService.cs:275-277` is `CreateIdpDatabase`, step 9).

**Evidence:**
- `src/processes/Invitation.Executor/InvitationProcessTypeExecutor.cs:111-151` (dispatch; `ProcessError` → `TODO` or `FAILED` + retrigger only)
- `src/processes/Invitation.Executor/InvitationProcessService.cs:69-83` (step 1 order: create, then `idp_name`), `:83,118,133,155,192,216,240,257,279` (step chain), `:260-280` (DB rows at step 9)
- `src/processes/Invitation.Executor/Extensions/InvitationProcessStepTypeIdExtensions.cs:27-41` (failure → `RETRIGGER_INVITATION_*`; one case per step at `:30-39`, default throws at `:40`)
- `grep 'ProcessTypeId.IDENTITYPROVIDER_PROVISIONING\|ProcessStepTypeId.DELETE_IDP_SHARED_REALM\b'` outside the executor → only `src/registration/Registration.Service/BusinessLogic/RegistrationBusinessLogic.cs:991,1003`
- `src/registration/Registration.Service/BusinessLogic/RegistrationBusinessLogic.cs:913-940` (decline), `:974-1015` (`ScheduleDeleteIdentityProviders`); `Controllers/RegistrationController.cs:497-503`
- `portal-2.6.0.tgz!values.yaml:397-403` (`applicationDeclineStatusIds`)
- `src/administration/Administration.Service/BusinessLogic/RegistrationBusinessLogic.cs:469-512` (operator decline, `SUBMITTED` only via `ApplicationRepository.cs:497`)
- `src/administration/Administration.Service/BusinessLogic/IdentityProviderBusinessLogic.cs:351-373` (`DeleteCompanyIdentityProviderAsync`), `:430-455` (`ValidateDeleteOwnCompanyIdentityProviderArguments`, admin delete preconditions)
- `src/externalsystems/OnboardingServiceProvider.Library/OnboardingServiceProviderBusinessLogic.cs:80-82` (OSP decline sets status only, no IdP deletion)
- `src/processes/IdentityProviderProvisioning.Executor/IdentityProviderProvisioningProcessTypeExecutor.cs:76-79,101-146` (the chain; all steps keyed on Portal DB `IdpData`)

**Status:** CONFIRMED (source at the deployed Worker commit). The `idp-3` interpretation and the
step-1 save race are INFERRED.

**Consequence for the roadmap:**
- On our own IDPs, **every failed test invitation leaks permanently** unless it is cleaned up by hand. Phase
  9 runs may accumulate objects. Phase 11 needs a cleanup runbook (or a script) keyed on `idp_name` and the
  Keycloak alias list, not on `iam_identity_providers`.
- **A15** should test **two** failure points: one before step 9 (expect: orphan with DB trace only in
  `company_invitations`) and one after submission (expect: cleanup only via operator decline). Then record
  what remains.
- Whether to add a Portal-side compensation step is a code change outside §2.1. **Question for Payam**, not
  planned here.

---

## Item 6 — Worker: every path that sets `BPNL_CREDENTIAL = DONE`

**Finding:** with `Onboarding:WalletProvider = IdentityHub`, the entry reaches `DONE` in three ways:

1. **Issuer callback.** `IssuerComponentBusinessLogic.StoreBpnlCredentialResponse` (Administration
   `…/registration/issuer/bpncredential`). It sets `DONE` for any status **other than `UNSUCCESSFUL`**. The
   enum has only `SUCCESSFUL` and `UNSUCCESSFUL`. It needs the entry `IN_PROGRESS` and the step
   `AWAIT_BPN_CREDENTIAL_RESPONSE`.
2. **Worker poll.** `IdentityHubCredentialAwaitBusinessLogic.AwaitCredentialResponse` sets `DONE` when the
   IdentityHub reports request state `ISSUED`. The request is looked up by the **deterministic**
   `holderPid = "<bpn-lower>-<credentialtype-lower>"`. Any earlier request with the same ID that reached
   `ISSUED` counts, regardless of which issuer, definition or attempt produced it. This is the "deterministic
   `BuildHolderPid`" defect in §4.7.
3. **Manual / out-of-band edit** of `application_checklist`. `ApplicationActivationService` explicitly
   anticipates this ("an entry advanced by hand"). Since `2cd5dd8a4`, activation **refuses** to proceed
   unless the **latest** `AWAIT_BPN_CREDENTIAL_RESPONSE` step also ended `DONE`.

`CreateBpnlCredential` (`REQUEST_BPN_CREDENTIAL`) sets only `IN_PROGRESS`. Retrigger endpoints set `TODO`.

**Which one produced the false `DONE` on `BPNL000000000342`:** cannot be decided offline. It needs the
`process_steps` history and checklist comment for that application, plus Worker and Administration logs
around the timestamp. **PENDING – NO CLUSTER ACCESS.** The candidates in order of likelihood (INFERRED):
(2) a stale or foreign `ISSUED` request under the deterministic PID; (1) a callback from a holder-side
extension; (3) a manual edit.

**Image commit ("2026-11-07 image"):** per the prepared record, on 2026-11-07 only
`portal-administration-service` moved to `274096a96`. The **Worker stayed on `ad459ee71`** until revision 3
(2026-11-09, `8ca2c1ecc`), then `2cd5dd8a4` (rev 4), then `e2451f876` (rev 5, digest `0857101e…`). All of
these contain the await-polling logic (path 2). Which image was live **when 0342 flipped** is
**PENDING – NO CLUSTER ACCESS** (Helm history + DB timestamp).

**Evidence:**
- `src/externalsystems/IssuerComponent.Library/BusinessLogic/IssuerComponentBusinessLogic.cs:47-83` (request → `IN_PROGRESS`), `:113-137` (callback → `DONE` unless `UNSUCCESSFUL`); `Models/IssuerResponseData.cs:29-33`
- `src/externalsystems/IdentityHub.Library/BusinessLogic/IdentityHubCredentialAwaitBusinessLogic.cs:60-74` (`ISSUED` → `DONE`)
- `src/externalsystems/IdentityHub.Library/IdentityHubService.cs:126-158,165-166` (PID lookup, state mapping)
- `src/registration/ApplicationActivation.Library/ApplicationActivationService.cs:322-370` (activation guard)
- `src/processes/ApplicationChecklist.Executor/ApplicationChecklistHandlerService.cs:61,82` (step bindings)
- `alpha/portal-release-prepared/images.lock.yaml:65-68` (2026-11-07 note), worker rows (`ad459ee71`, `8ca2c1ecc` rev 3, `2cd5dd8a4` rev 4, `e2451f876` rev 5)
- `git cat-file -e <commit>:…/IdentityHubCredentialAwaitBusinessLogic.cs` → present in `274096a96`, `ad459ee71`, `8ca2c1ecc`, `2cd5dd8a4`, `e2451f876`

**Status:** paths CONFIRMED. Attribution for 0342 and the live image at that moment are PENDING.
**Consequence:** Phase 4 fix of the false `DONE` should make path 2 match the **current** request, for example
by using a unique request ID per attempt (already planned as "new unique request id per retry").

---

## Item 7 — Caller of `RequestCredentialAsync` and values in scope

**Finding:**

| Level | Values in scope |
|---|---|
| `IssuerComponentBusinessLogic.CreateBpnlCredential` / `CreateMembershipCredential` | `context.ApplicationId`, the context checklist, `holder` (= `companies.did_document_location`), `businessPartnerNumber`, `walletInformation`, `isBringYourOwnWallet`, `callbackUrl`, and for membership `memberOf = "arena-x"` |
| → `IIssuerComponentService.CreateBpnlCredential(CreateBpnCredentialRequest data)` | `Holder`, `BusinessPartnerNumber`, `TechnicalUserDetails` (null for IdentityHub), `CallbackUrl`. **No application ID.** |
| → `IdentityHubIssuerComponentService` → `RequestCredentialAsync(bpn, credentialType, credentialDefinitionId)` | BPN, type and definition ID from settings. `MemberOf`, `Holder` and `CallbackUrl` are **dropped**. |
| → `RegisterHolderWithIssuerAsync(normalizedBpn)` → `HolderProperties(contractVersion)` | **only** BPN and `FrameworkContractVersion` |

The **approval timestamp is not in scope anywhere** on this path. The application ID exists only at the
business-logic level and is not passed down.

**Consequence for Phase 4** (`HolderProperties` + `bpn`, `approvalSource`, `applicationId`, `approvedAt`):
- `CreateBpnCredentialRequest` / `CreateMembershipCredentialRequest`, or the `IIssuerComponentService`
  signature, must carry the application ID.
- `approvedAt` needs a repository read. The candidates are the `REGISTRATION_VERIFICATION` entry or the
  application's `DateLastChanged`. Which one is "approval" is a Phase 4 decision.
- The interface is shared with the non-IdentityHub implementation, so the change touches both.
- For D6: `memberOf` already exists (`"arena-x"`, item 2) but the IdentityHub path never sends it.

**Evidence:**
- `grep -rn 'RequestCredentialAsync\|RegisterHolderWithIssuerAsync\|HolderProperties('` → `IdentityHubIssuerComponentService.cs:49,55`, `IdentityHubService.cs:87,95,179,185`
- `src/externalsystems/IdentityHub.Library/IdentityHubService.cs:87-123,179-203,230-237`
- `src/externalsystems/IssuerComponent.Library/Models/CreateBpnRequest.cs:24-37`
- `src/externalsystems/IssuerComponent.Library/BusinessLogic/IssuerComponentBusinessLogic.cs:47-72,139-165`
- `src/portalbackend/PortalBackend.DBAccess/Repositories/ApplicationRepository.cs:549-563`

**Status:** CONFIRMED.

---

## Item 8 — `bdrs-server` 0.6.0

**Finding:**

*Chart.* `bdrs-server` 0.6.0, appVersion 0.6.0. Subcharts: `postgres` (cloudpirates 0.18.3, condition
`install.postgresql`) and `vault` (hashicorp 0.28.0, condition `install.vault`). Ports: 8080 `/api`
(health), **8081 `/api/management`** (token-based, header `X-Api-Key`), 8082 `/api/directory`.

*Defaults that are wrong for us:*
- `postgresql.persistence.enabled: false`, `storageClass: standard`
- `postgresql.auth.password: "password"`
- `vault.server.dev.enabled: true` with `devRootToken: "root"`
- `vault.hashicorp.token: "root"` — **dev-mode, in-memory Vault**, the same failure class as the
  2026-11-12 incident

*Secrets come from Vault, not from env.* The DB user and password are read from Vault aliases
`edc.datasource.didentry.user` and `.password`. The management API key is read from Vault alias
`authKeyAlias` (default `mgmt-api-key`). **So "own BDRS, PostgreSQL-backed" also means a Vault for BDRS.**
The Vault token can be a `secretKeyRef` via `server.envValueFrom.EDC_VAULT_HASHICORP_TOKEN`.
`server.trustedIssuers` **must not be empty** (the template fails), so it has to name our issuer DID.

*The umbrella already has a production-shaped pattern* (`be293Provisioning`, the DEV overlay
`values-be293-persistent-bdrs.yaml`):
- Postgres with PVC (5Gi)
- a **separate Raft-storage Vault** (`dev.enabled: false`, PVC 1Gi)
- an init container (`files/be293-bdrs-vault-provision.sh`, non-root, read-only root FS) that writes the
  three aliases from mounted Secrets, write-once with check-and-set
- a NetworkPolicy so that only BDRS reaches its Vault on 8200
- a post-install Job seeding `bpnList`

Do **not** copy two things from the DEV overlay: it exposes `management` on the Ingress (the chart says it
"must not be internet facing"), and it uses a static Vault token.

*Portal settings that must be repointed — more than the two in §4.3:*

| Setting | Component | Current |
|---|---|---|
| `BPNDIDRESOLVER__BASEADDRESS` | worker | `http://bdrs-server.release26-09.svc.cluster.local:8081` (`bpnDidResolver.managementApiAddress`) |
| `BPNDIDRESOLVER__APIKEY` | worker | Secret `be293-portal-bdrs` / `management-api-key` |
| `SERVICES__BPNDIDRESOLVERURL` | services | `bpnDidResolver.directoryApiAddress` = `https://bdrs-server.test.tractus-x.com/api/directory` |
| `COMPANYDATA__BPNDIDRESOLVERURL` | administration | same |
| `APPMARKETPLACE__BPNDIDRESOLVERURL` | appmarketplace | same |
| `BPNDIDRESOLVER_DIRECTORY_URL` | frontend portal | same |
| NetworkPolicy `be293-portal-release26-09-egress` BDRS rule | — | `namespaceSelector release26-09`, `instance: bdrs-server`, 8081 |

The four directory references are **reads** of his public directory, so they do not break the read-only
rule. But after the switch his directory would not contain our BPN→DID mappings. **Question for Payam:**
repoint them to our BDRS (which then needs a public directory Ingress) or leave them.

*Provenance:* `VALIDATION.md` §5 records that `bdrs-server 0.6.0` **differs from the published digest; content
was not compared**. Treat the pinned tgz as unverified. This is the same concern as item 10.

Note: the `BpnDidResolver` client in the Portal posts to `api/management/bpn-directory`, with the header
`X-Api-Key`.

**Evidence:**
- `bdrs-server-0.6.0.tgz!Chart.yaml`; `values.yaml:26-28` (install flags), `:82-104` (endpoints), `:108` (`trustedIssuers`), `:268-307` (postgres/vault defaults)
- `bdrs-server-0.6.0.tgz!templates/deployment.yaml:154-157,175-180` (Vault-alias comment), `:187-202,209-215` (non-empty issuer check), `:221-239`
- `portal-backend-await-fix/src/externalsystems/BpnDidResolver.Library/BpnDidResolverService.cs:34`; `DependencyInjection/BpnDidResolverSettings.cs:24-30`; `BpnDidResolverServiceCollectionExtension.cs:31-45`; `src/processes/Processes.Worker/Program.cs:66`
- `portal-2.6.0.tgz!templates/cronjob-backend-processes.yaml:373-379`; `deployment-backend-services.yaml:258`, `deployment-backend-administration.yaml:310`, `deployment-backend-appmarketplace.yaml:277`, `deployment-frontend-portal.yaml:77`
- `alpha/portal-release-prepared/values-be293-portal.yaml:44-48`; `secrets-contract.yaml:62-65`; `networkpolicies-be293-portal.alpha-release.yaml:131-140`; `alpha-service-map.yaml:55-59`
- `handoff/BE-293-umbrella-3.17.0/chart/umbrella/Chart.yaml:103-115`; `templates/configmap-bdrs-provision.yaml`, `templates/networkpolicy-bdrs-vault.yaml`, `templates/post-install-bdrs-setup.yaml:32-150`; `files/be293-bdrs-vault-provision.sh`
- `~/Backup/Projects/public-tractus-x-umbrella/charts/values-be293-persistent-bdrs.yaml` (read with secrets redacted)
- `tx-umbrella-0.13-integration/recovery/be293-dev-3.17.0/VALIDATION.md:78`

**Status:** CONFIRMED (chart, templates, source). INFERRED: that the DEV persistent-BDRS overlay worked as
intended on DEV.

---

## Item 9 — DEV blueprint: `identity-and-trust-bundle` and its seed job

**Finding:**
- `identity-and-trust-bundle` 1.2.0 (DEV) bundles `ssi-dim-wallet-stub` 0.1.14, `tractusx-identityhub-memory`
  v0.3.2 (alias `identity-hub`), `tractusx-identityhub` v0.3.2 (alias `identity-hub-postgres`) and
  `tractusx-issuerservice` v0.3.2 (alias `issuer-service`). **BDRS is not in the bundle.** It is an umbrella
  dependency (item 8).
- The seed job (`tx-data-provider/templates/post-install-identityhub-seed.yaml`, 1102 lines) does the following:
  - IssuerService: create and activate the issuer context, then POST `/api/admin/v1alpha/participants/{issuerCtx}/{attestations,credentialdefinitions,holders}`.
  - IdentityHub: create and activate the holder context, then `credentials/request` and retrieve.
  - The participant ID is **plain** in URLs (already in §4.7).
- **Security-relevant:** the job gets the super-user API keys by **grepping pod logs** for `"Please take note
  of the API Key: …"`. It falls back to `--previous` logs, then to reading the key back from Vault. The
  IdentityHub/IssuerService `SuperUserSeedExtension` logs the key **at INFO on first boot, even when the key
  is preset** via `edc.ih.api.superuser.key`. That breaks DoD 7 / A7 ("no secret in logs") out of the box.
  The seed job's RBAC also needs `pods/log`.

**Evidence:**
- `~/Backup/Projects/public-tractus-x-umbrella/charts/identity-and-trust-bundle/Chart.yaml` (dependencies), `charts/` (4 tgz)
- `…/charts/tx-data-provider/templates/post-install-identityhub-seed.yaml:13-25` (call list), `:193` (plain ID note), `:286-330` (log scraping, Vault fallback)
- `~/Backup/Projects/public-tractusx-identityhub-be293/extensions/seed/super-user/src/main/java/org/eclipse/tractusx/identityhub/seed/SuperUserSeedExtension.java:46-47,67,90-103`

**Status:** CONFIRMED for the DEV sources. INFERRED: that the official `tractusx/identityhub:0.4.1` /
`issuerservice:0.4.1` images contain the same logging line (the extension comes from upstream; the image was
not inspected).

**Consequence:** the Phase 2 ADR must say how the super-user key is set without it appearing in logs. Options
include preset key + log-level control for that logger, or rotating the key after first boot and treating the
first-boot log as sensitive. It must also say that our seed job does **not** scrape logs. Not planned here.

---

## Item 10 — Chart provenance: are the `recovery*` fields local edits?

**Finding: Yes, confirmed.** The pinned `centralidp-4.2.1.tgz` and `sharedidp-4.2.1.tgz` are local forks that
carry the upstream version string `4.2.1`.

- The repo's own provenance record says: *"bpdm 6.2.0, centralidp 4.2.1, sharedidp 4.2.1, portal 2.6.0 |
  Locally modified forks of the published releases (1, 2, 3 and 6 changed files). The changes add Helm
  `lookup` recovery, IdentityHub Portal settings and Secret references."*
- Diff against a non-recovery copy (`tx-umbrella-0.13/…/centralidp-4.2.1.tgz`, sha256 `9e4524fb…`):
  - `values.yaml`: `+recoveryExistingRevision`, `+recoveryExistingRevisions`, `+recoveryPreserveExistingJobs`, `+recoveryImageByRevision`.
  - `templates/job-seeding.yaml`: multi-revision loop; `lookup "batch/v1" "Job"` that copies a **live** Job spec verbatim when `recoveryPreserveExistingJobs`; per-revision image override; `imagePullSecrets`; optional Keycloak-service TLS CA (`keycloakServiceTlsCaSecret/Key`, not declared in `values.yaml`).
- Origin: commits `c5ec396`, `3e614d0`, `60c0b81` (2026-10-30, Payam). The chart was "recovered from a
  deployed Helm release … reassembled from the release record and the matching dependency packages".
- The same fork (`17ce0bfe…`) is also in the DEV backup.

**Consequence:** these `.tgz` files are **not reproducible from upstream** and must be pinned by digest as
BE-293 artefacts. With all recovery values at their defaults, the only render-time differences are
`imagePullSecrets` support, the TLS CA option and the one-line `CONNECTIONSTRING`. The `lookup` path is inert
unless `recoveryPreserveExistingJobs: true`. For a clean new install the ADR should state one of two things:
either use the published 4.2.1 charts, or keep the fork with the recovery values explicitly empty and a test
asserting that. The same unverified status applies to `bdrs-server 0.6.0` (item 8).

**Evidence:**
- `tx-umbrella-0.13-integration/recovery/be293-dev-3.17.0/VALIDATION.md:70-80` (dependency provenance table, line 77)
- `diff -r <0.13 copy>/centralidp <pinned>/centralidp` (output summarised above)
- `git log -S'recoveryPreserveExistingJobs'` in `tx-umbrella-0.13-integration` → `c5ec396`, `3e614d0`, `60c0b81`, `73c5541`, `e55455a`
- sha256 prefixes: pinned centralidp `17ce0bfe…`, sharedidp `0cad40f1…`; alternate centralidp `9e4524fb…`

**Status:** CONFIRMED that they are local edits. INFERRED that the `9e4524fb…` copy is byte-identical to
upstream: upstream was not fetched (offline).

---

## Cluster-dependent items — not done

| Item | What is needed | Status |
|---|---|---|
| 4 | `portal` schema dump; orphan query above | PENDING – NO CLUSTER ACCESS (+ approval for `pods/exec`) |
| 2 (part) | `iam_clients` rows; shared CX-Central scopes | PENDING – NO CLUSTER ACCESS |
| 3 (part) | Live env of deployments/CronJob vs prepared values | PENDING – NO CLUSTER ACCESS |
| 6 (part) | 0342 step history; Helm history at that time | PENDING – NO CLUSTER ACCESS |
| D2 | ExternalDNS deployed and reconciling (§4.6) | PENDING – NO CLUSTER ACCESS |
| 1 (part) | `CX-Operator` / `master` realm JSON from `tractusx/portal-iam:v4.2.0` | PENDING – needs an image pull (outbound) |

---

## Gate 1 summary

| Decision | Answer from this pass | Item |
|---|---|---|
| D1 (outbound token trust) | Decided (a). Holds in code. **Implementation needs a Portal chart patch** to decouple the BPDM token endpoint from `centralidp.address`. | 3 |
| D2 (ExternalDNS) | PENDING – NO CLUSTER ACCESS | — |
| D4 (Portal DB) | No change to the recommendation. **Run the `company_invitations.idp_name` orphan query before any re-seed.** Schema dump pending. | 4, 5 |
| BDRS | Decided (own). Needs its own Vault too; the umbrella `be293Provisioning` pattern exists; 4 extra directory references + 1 NetworkPolicy to repoint. | 8 |
| `arena` scope | Not a login/onboarding blocker. Affects offer-client creation. Fix in **seed** or **Portal config**, not by hand. | 2 |
| Failed-invitation cleanup | None automatic. Orphans from steps 1–8 are invisible to every deletion path. | 5 |

## Questions for Payam (not planned, not acted on)

1. **`arena`:** (a) add the scope to our CX-Central seed (BE-293 init-container variant), or (b) restore
   `catena` in the Portal (image rebuild or chart env patch)?
2. **CX-Central seed source:** the umbrella init container (includes `satest01…16`) or the stock
   `portal-iam:v4.2.0`?
3. **BDRS directory URL:** repoint the four directory references (and add a public directory Ingress), or
   keep reading the shared directory?
4. **Failed invitations:** accept manual cleanup (runbook + A15 test), or consider a Portal compensation step?
   The second would be a code change outside §2.1.
5. **IdentityHub/IssuerService super-user key in logs:** the ADR needs an approach that satisfies A7.
6. **Chart forks:** use published 4.2.1 IDP charts for the new stack, or keep the recovery forks pinned as
   BE-293 artefacts?

**STOP — Gate 1.** No ADR, chart, values, branch or cluster work until this report is reviewed.
*(Gate 1 passed 2026-11-16 — see header. Decisions taken at Gate 1 are recorded in roadmap v5 §0.)*

---

## Addendum A — Offline audit of commit `43767079b` ("chore:ARENA branding")

**Scope:** every file the commit changed: 102 files, 201 lines added and 201 removed. The audit asks: which
renamed identifiers are **wire-level** or **configuration-contract** identifiers (a name another system or
the deployment relies on), and which are text only?

**Method:**
- `git show --stat 43767079b`
- `git show -U0 43767079b -- <file>` for every shipped file (anything under `src/` and `docs/api/`; test
  and Postman files were classified from the file list)
- a usage grep at `e2451f876` for each renamed identifier

Read-only; nothing was built or run.

### A.1 Wire-level identifiers (runtime contract with another system)

| # | Identifier | Where (now) | Counterpart | State at `e2451f876` | Effect |
|---|---|---|---|---|---|
| W1 | Keycloak client scope `catena` → `arena` | `Processes.Worker/appsettings.json:274`, `Apps.Service/appsettings.json:147`, `Services.Service/appsettings.json:144` | CX-Central realm (seed has `catena` only) | **OPEN** | Offer clients lack the `bpn`/`organisation` claims, or creation fails (item 2) |
| W2 | BPDM JSON `isCatenaXMember` → `isArenaXMember` | `Bpdm.Library/Models/BpdmCxMembershipDto.cs:39` | BPDM Pool v6 `cx-memberships` | **FIXED** in `e2451f876` | — |
| W3 | BPDM JSON `isCatenaXMemberData` → `isArenaXMemberData` (2×) | `Bpdm.Library/Models/BpdmLegalEntityDto.cs:35,91` | BPDM legal-entity response, deserialised at `BpnAccess.cs:42` | still renamed | The field always deserialises to `false`. **No consumer:** `grep IsArenaXMemberData src` finds only the DTO. No functional effect today. BPDM is out of scope (§2.1 C); record only. |
| W4 | Membership `memberOf` `"catena-x"` → `"arena-x"` | `IssuerComponent.Library/BusinessLogic/IssuerComponentBusinessLogic.cs:163` | SSI credential issuer (non-IdentityHub path) | still renamed | Not sent on the IdentityHub path (item 7). Input for D6. |

### A.2 Configuration-contract identifiers (names the deployment must use)

| # | Identifier | Where | Effect |
|---|---|---|---|
| C1 | Setting `CatenaAdminRoles` → `ArenaAdminRoles` | `Apps.Service/BusinessLogic/AppsSettings.cs`, `Services.Service/ServiceSettings.cs:38`, both `appsettings.json` | The default is `[]` both before and after. The Portal chart sets neither name (`grep ADMINROLES portal-2.6.0.tgz!templates` → only `COMPANYADMINROLES`, `ITADMINROLES`, `USERADMINROLES`, `ACTIVEAPPCOMPANYADMINROLES`). **No behaviour change.** Any future override must use `…__ARENAADMINROLES__…`; the upstream name would be silently ignored. |

### A.3 Not wire-level (text only; no action)

| Change | Where |
|---|---|
| CORS policy name constant `_catenaXAllowSpecificOrigins` → `_arenaXAllowSpecificOrigins` | `Framework.Cors/CorsExtensions.cs:31`. Process-internal key. |
| 12 e-mail subjects "Catena-X" → "Arena-X" | `Processes.Worker/appsettings.json:480-571` (12 lines) |
| Seeded description texts | `PortalBackend.Migrations/Seeder/Data/{agreement,company_role,user_role}_descriptions.json`. Display text seeded into `portal` tables. |
| XML-doc and OpenAPI examples `CAXSDUMMYARENAXZZ` | `Administration.Service/Controllers/UserController.cs:274`, `docs/api/administration-service.yaml:5840` |
| Static HTML templates | `Mailing.Template/EmailTemplates/staticTemplates/basicTemplate.html:288` (inside an HTML comment); `buttonTemplate.html:444` (**live** `<a href>` to `arenax-dev003-app-portal.azurewebsites.net`) |
| Docs, NOTICE, CHANGELOG, csproj metadata, README, Postman names, tests | not shipped behaviour |

**Hygiene note (INFERRED, low):** `buttonTemplate.html:444` points at an Azure host that is not ours (upstream
pointed at an equally stale `catenax-dev003…`). If an e-mail ever rendered it, the link would lead to a
domain anyone could register. The `staticTemplates/` files are **not referenced** by any `[Path(...)]` in
`Mailing.Template/Enums/EmailTemplateType.cs`, and `grep -rn 'staticTemplates\|buttonTemplate' src` finds
no reference, so it is inferred unused. Recorded only; out of scope.

**Conclusion:** the commit changed **four wire-level identifiers**:
- W1 is open — the `arena` decision (roadmap v5, Phase 2 ADR).
- W2 is fixed.
- W3 has no consumer.
- W4 is not on the IdentityHub path and feeds D6.

No other renamed identifier reaches Keycloak, BPDM, the issuer, IdentityHub, BDRS or the database
schema. Within the scope of this commit, nothing else will fail after the switch.

**Status:** CONFIRMED (diff + usage grep at `e2451f876`). The static-template exposure is INFERRED.
