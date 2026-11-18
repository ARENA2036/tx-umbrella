# BE-293 Alpha — Portal Test Replica in `be293`: Roadmap v4

**Date:** 2026-11-13
**Supersedes:** v3, v2 (2026-11-13), v1 (2026-11-12)
**Owner:** Payam (BE-293) · Decision: David Görzig · Coordination: Saud Khan
**Status:** Plan. Phase 1 partially complete — findings in §4. Gate 0 still open.

**Purpose:** build a replica in `be293` to test the new BE-293 Portal and its components safely on the
Alpha cluster, isolating only the components that must be isolated. If it works, Saud changes the
shared environment over to the new Portal. Nothing here is a permanent parallel platform.

---

## 0. What changed in v4

v3 expanded the scope beyond what was asked. v4 pulls it back to the replica's actual purpose and
separates what Saud requested from what we decided ourselves (§2.1).

| | v3 | v4 |
|---|---|---|
| **BPDM** | deferred own-BPDM phase, with a BPN-reassignment decision | **removed. BPDM is unchanged** — public testbed, `sa-cl7-cx-5`. No demonstrated technical reason to change it. |
| **D7** (BPN reassignment) | open at Gate 0 | **removed** — it only existed to serve the own-BPDM phase |
| **BDRS** | "DECIDED", stated as forced | **decided by Payam 2026-11-13**: own PostgreSQL-backed instance. Recorded as a decision under the read-only rule, not as a technical failure of the shared one. |
| **DNS** | "no wildcard, ask Saud for four records" | **corrected and now PENDING VERIFICATION** — ExternalDNS appears to create records from the Ingress annotation (§4.6) |
| **Questions for Saud** | four | **two** |
| Framing | "self-contained stack" | **test replica** (§2) |

### v2 → v3 (retained for history)

v2 was written before any evidence. v3 records what Phase 1 actually proved, which closed three
open questions and opened two new ones.

| | v2 | v3 |
|---|---|---|
| **D1** (outbound token trust) | open, +0 to +4 days | **decided: (a), proven in source** |
| **BDRS** | "own / skip / keep shared — decide in Phase 1" | **own, in scope** — forced by the read-only rule |
| **BPDM** | part of the D1 decision | **deferred to its own later phase**, with the BPN question attached |
| Helm releases in `be293` | `be293-portal`, `be293-iam`, `be293-identity` | unchanged; BDRS joins `be293-identity` |
| Still shared after the switch | unknown | **BPDM gate and pool on the public testbed only** |
| Writes into `release26-09` | not yet forbidden | **forbidden** — see §3 |

**The shape, in one line:** own identity plane, shared data plane. Every user, company, realm,
identity provider, credential, DID and BPN→DID mapping becomes ours. The only thing we keep on
someone else's infrastructure is a single machine credential against the public BPDM testbed.

---

## 1. The request that started this

> *"I just saw that there are users and companies registered in a centralidp, that is being used by
> Catena-X testbed. Could you please use a separate centralidp and sharedidp for your portal testing,
> instead of using the central one?"*

The realm our Portal has been provisioning into holds another project's users and companies. Our
Portal does not only read from it: every partner invitation creates an identity provider in
`CX-Central` and a realm in `sharedidp`. Four such pairs exist today (§4.4).

This is also why two long-standing defects look the way they do:

- **A07 (`idp2` alias collision)** — a collision in a realm shared with a testbed is most likely a
  name already taken by someone else. Our aliases are now `be293-alpha-idp-N` and the sequence shows
  no collisions, so the prefix fix appears to be deployed and working. `[INFERRED]`
- **`0342` `APPLICATION_ACTIVATION` 401** at their token endpoint may not be our misconfiguration at
  all — it could be access tightening on their side, or a changed service account. **Do not spend
  more time fixing this against their realm.** Re-test it on ours. `[INFERRED]`

---

## 2. Goal

Test the new BE-293 Portal safely on the Alpha cluster, with isolated components where isolation is
necessary, without affecting the shared Catena-X environment. Login, invitation, onboarding and
credential issuance must work end to end in `be293`, write nothing into `release26-09`, and survive
pod and node restarts.

Isolation is a means, not the objective. A component is isolated only where there is a stated
requirement or a demonstrated technical reason (§2.1). Everything else stays as it is.

## 2.1 Scope — who asked for what

Keeping these apart matters: Saud's requirement is not negotiable, our decisions are ours to revisit,
and anything in neither list is out of scope.

### A — Saud's explicit requirement

1. **Separate CentralIDP and SharedIDP for BE-293 Portal testing.** Our test users and companies were
   being registered in a CentralIDP used by the Catena-X testbed.

That is the whole list.

### B — Our technical decisions, with reasons

2. **Own Vault, IssuerService, IdentityHub.** Saud confirmed the shared Vaults use in-memory storage;
   the 2026-11-12 node event lost key material and there is no recovery procedure (§4.7).
   *Demonstrated technical reason.*
3. **Own BDRS, PostgreSQL-backed.** Decided by Payam, 2026-11-13. `TransmitDidAndBpn` writes into
   `bdrs-server.release26-09` (§4.3), and Portal testing must not write or modify data there.
   *Decision under the read-only rule, not a failure of the shared instance.*

### C — Explicitly out of scope

4. **BPDM is unchanged.** Public testbed (`business-partners.test.tractus-x.com`), `sa-cl7-cx-5`,
   `client_credentials`. Not in `release26-09`, not part of Saud's request, and no demonstrated
   technical reason to change it. Not to be revisited without one.
5. **No other component is rebuilt**, replicated or re-architected on the strength of this work.

**Definition of done**

1. A human logs into the BE-293 Portal through **our** SharedIDP, brokered by **our** CentralIDP.
2. Partner invitation creates a realm and identity provider **in ours**, with a unique alias, and the
   invitation mail arrives.
3. An approved company completes `IDENTITY_WALLET`, `BPNL_CREDENTIAL` and `MEMBERSHIP_CREDENTIAL` with
   real, verifiable credentials; `APPLICATION_ACTIVATION` reaches `DONE`.
4. An unapproved holder receives no credential.
5. **Zero writes into `release26-09`** — provable from configuration and NetworkPolicy, not assumed.
6. Deleting every pod of both stacks loses no keys, realms, users or BPN→DID mappings.
7. No secret in logs, Git, values or Helm manifests. No change outside `be293`.
8. Tests, lint and security checks run after the last edit, with recorded results.

**Accepted limits (Gate 0):** credentials from this issuer are trusted only inside BE-293.
Connectors in `connector` and services in `release26-09` do not trust it. BPNs continue to come from
the shared BPDM pool, unchanged (§2.1 C).

---

## 3. Rules for every phase

| Rule | Detail |
|---|---|
| **`release26-09`** | **Read-only. No change or modification of data, under any circumstance.** `get`, `logs` and read-only queries only. This is absolute and overrides convenience: it is what moved BDRS in scope (§4.3). |
| Namespaces | Change only `be293`. Every other namespace: do not touch without asking. |
| Cluster | Always `--kubeconfig ~/.kube/alpha.yaml --context alpha`. Never the default context. DEV is reference only. |
| Gates | Stop at every gate and report. No live change without approval for that specific step. |
| Before any live change | Target, server-side dry-run, diff, rollback, and a backup where data is involved. |
| Secrets | Never print, log, commit or paste secret values. Never on the command line. Key names only. |
| Vault | No in-memory or dev-mode Vault. No root token in applications. |
| Keycloak | Production mode. External database with a PVC. Proxy headers set explicitly. Admin REST API never reachable from outside the cluster. No seeded placeholder secret survives into a running realm. |
| Keys | No super-user keys in the Portal. Scoped keys only. |
| Git | Preserve uncommitted work. No push or PR without approval. **No AI attribution anywhere** — commits, PR titles and descriptions, comments, release notes, docs, source. Use the existing Git identity. |
| Evidence | Distinguish observed, prepared, deployed and verified. Never claim an unproduced result. |
| Conventions | Follow `alpha/portal-release-prepared`: `values-be293-*.yaml`, `images.lock.yaml`, `secrets-contract.yaml` (key names only), `expected-inventory*.txt`, offline gates in `tools/render-release.sh`, Ruby tests under `tests/`. |
| Shell | zsh. `setopt interactive_comments`, quote every glob, `K` is a function not a variable. |

---

## 4. Confirmed findings

Everything in §4.1–§4.6 was observed on 2026-11-13 with evidence. `[INFERRED]` marks anything that is
reasoning rather than observation.

### 4.1 D1 — DECIDED: option (a), no code change

The Portal resolves the outbound token endpoint **per integration**, independently of the login
authority:

- `framework/Framework.Token/TokenService.cs:41,80,103` — posts to `settings.TokenAddress`
- `framework/Framework.Token/GetBasicTokenSettings.cs:26`, `BasicAuthSettings.cs:33`,
  `KeyVaultAuthSettings.cs:46` — `TokenAddress` is a per-settings property
- `Processes.Worker/appsettings.json` — `ApplicationChecklist:{Bpdm,Custodian,SdFactory,Clearinghouse,Dim}`,
  `OfferProvider`, `OnboardingServiceProvider` each carry their own
  `ClientId / ClientSecret / GrantType / Scope / TokenAddress`
- `Keycloak:central` and `Keycloak:shared` are a separate section (`ConnectionString / ClientId /
  ClientSecret / AuthRealm`), used only for the admin and provisioning client

Live worker environment confirms the grant is machine-to-machine:

```
APPLICATIONCHECKLIST__BPDM__GRANTTYPE  = client_credentials
APPLICATIONCHECKLIST__BPDM__SCOPE      = openid
APPLICATIONCHECKLIST__BPDM__CLIENTID   = 11 chars  (matches sa-cl7-cx-5)
APPLICATIONCHECKLIST__BPDM__TOKENADDRESS
  = https://centralidp.test.tractus-x.com/auth/realms/CX-Central/protocol/openid-connect/token
```

`USERNAME` and `PASSWORD` are set (5 chars each) but **unused** under `client_credentials` — almost
certainly dead placeholder config. They are inline `value` entries in the CronJob spec rather than
`secretKeyRef`. Empty them when those values are next touched, after confirming they are not real.

**Decision:** move login, realms, identity providers and company provisioning to our own IDPs. Keep
`sa-cl7-cx-5` in the shared CentralIDP for BPDM only. It creates no users, companies or realms.
**Accepted risk:** if that account is rotated or deleted, the `BUSINESS_PARTNER_NUMBER` checklist step
breaks. Ask Saud to confirm this is acceptable and to warn us before rotating it.

### 4.2 BPDM is on the public testbed, not in `release26-09`

```
APPLICATIONCHECKLIST__BPDM__BASEADDRESS                  = https://business-partners.test.tractus-x.com/gate/v6
APPLICATIONCHECKLIST__BPDM__BUSINESSPARTNERPOOLBASEADDRESS = https://business-partners.test.tractus-x.com/pool/v6
```

So "separate from Saud's namespace" and "separate from the Catena-X testbed" are different scopes.
BPDM is in the second. The read-only rule does not reach it; writing partner data into a gate is what
a gate is for.

### 4.3 BDRS — own instance, decided by Payam 2026-11-13

**Decision basis:** Portal testing must not write or modify data in `release26-09`. This is a scope
rule, not a finding that the shared BDRS is defective. Recording it this way so it can be revisited
on its own terms if the rule ever changes.

`BPNDIDRESOLVER__BASEADDRESS = http://bdrs-server.release26-09.svc.cluster.local:8081`, and
`BpnDidResolver.Library/BusinessLogic/BpnDidResolverBusinessLogic.cs:88` calls `TransmitDidAndBpn` —
a **write** into `release26-09`. `ApplicationChecklist.Executor/ApplicationChecklistHandlerService.cs:60`
binds `TRANSMIT_BPN_DID` to `ApplicationChecklistEntryTypeId.IDENTITY_WALLET`, so it fires on every
onboarding and the wallet step does not complete without it.

Under §3 this cannot stay shared. The umbrella already pins both variants:

```
bdrs-server-0.6.0.tgz          ← use this one
bdrs-server-memory-0.6.0.tgz   ← do NOT use
```

The umbrella's own `Chart.yaml:107-115` says the memory variant loses the BPN→DID directory on a pod
or VM restart, and that both render as `bdrs-server` via `fullnameOverride`, so exactly one may be
enabled. Use the PostgreSQL-backed chart with a PVC. Same failure class as the in-memory Vault
incident; the comment exists because someone already learned it.

Portal-side change is two settings: `BPNDIDRESOLVER__BASEADDRESS` and its API key. **Note:** our
directory starts empty. Existing mappings in his BDRS do not come with us — acceptable because we
re-onboard, but state it so nobody expects otherwise.

### 4.4 What we have left in the shared IDPs

From `portal.iam_identity_providers` joined to `identity_providers` and `companies`:

| Alias | Company | BPN | Type |
|---|---|---|---|
| `be293-alpha-idp-3` | BE293 Onboarding E2E 0002 | — (failed before BPN assignment) | SHARED |
| `be293-alpha-idp-4` | BE293 Onboarding E2E 0003 | BPNL000000000342 | SHARED |
| `be293-alpha-idp-5` | Blue Sky | BPNL00000000043D | SHARED |
| `be293-alpha-idp-6` | Green Land | BPNL00000000052O | SHARED |

`IdentityProviderTypeId.cs:25-27` — `OWN=1, MANAGED=2, SHARED=3`. All four are SHARED, so **each is
two objects on his side**: an identity provider in `CX-Central` *and* a realm in `sharedidp` under the
same alias.

`CX-Operator` / `BPNL00000003CRHK` / Catena-X also appears in our table. **That is his**, the seeded
operator (`realmSeeding.bpn: BPNL00000003CRHK` in the centralidp chart). Not ours, not on the list.

Our records show no `be293-alpha-idp-1` or `-2`. If they exist on his side they predate our current
state and we cannot enumerate them — say so rather than implying the list is exhaustive.

**New finding — failed onboardings leak identity objects.** `Invitation.Executor/InvitationProcessService.cs:275-277`
creates the identity provider, the company link and the IAM alias early in the invitation process,
long before BPN assignment. `be293-alpha-idp-3` is the proof: a failure after invitation left a live
alias and a live realm with nothing behind them. The deletion machinery exists
(`IdentityProviderProvisioningProcessTypeExecutor.cs:78,105,137,150` — `DELETE_IDP_SHARED_SERVICEACCOUNT`,
`DELETE_CENTRAL_IDENTITY_PROVIDER`, `DELETE_IDENTITY_PROVIDER`) but **whether anything triggers it on a
failed invitation is unknown**. On our own IDPs this will accumulate across every test run. Phase 1
item 13 must answer it; Phase 10 adds a deliberate mid-flow failure test.

### 4.5 The IDP charts

`centralidp-4.2.1` and `sharedidp-4.2.1` are both in the pinned umbrella, both with their own
`templates/`, so both install standalone. Keycloak **25.0.6** via Bitnami subchart **23.0.0**.

**Good news on secrets.** `realmSeeding.clients.existingSecret`, `serviceAccounts.existingSecret`,
`extraServiceAccounts.existingSecret`, and sharedidp's `realms.cxOperator.existingSecret` /
`realms.master.existingSecret` all exist. **No client secret needs to be a literal in a values file.**
This fits the existing `secrets-contract.yaml` convention exactly.

**Four defaults that are wrong for us**, all confirmed in the shipped values:

| Default | Value | Why it is wrong |
|---|---|---|
| `keycloak.production` | `false` in **both** charts | dev mode |
| `proxyHeaders` / `proxy` | both `""` | `charts/keycloak/templates/configmap-env-vars.yaml:19-20` sets `KEYCLOAK_PROXY_HEADERS: xforwarded` **only** when `proxy` is set and `proxyHeaders` is empty. Leave both unset → nothing configured → **tokens get the wrong issuer.** Same bug class as the issuer-service `http` vs `https` warning. Assert the issuer in a real token, not the config. |
| `ingress.hostnameStrict` | `false` | should be `true` with an explicit hostname |
| `postgresql` | `bitnamilegacy/postgresql:15-debian-11`, `storageClass: ""` | the chart's own comment calls it *"recommended for demonstration purposes only"*; floating tag; storage class must be set explicitly. Persistence defaults on at 8Gi. |

`adminIngress` is a **separate** ingress and is disabled by default — correct — but that does **not**
stop `/auth/admin` being reachable on the main ingress host. Blocking it needs an explicit nginx rule.

Seeding resources are already raised (centralidp 850M, sharedidp 700M), consistent with the known
OOMKilled history.

**Chart provenance — open question.** Both `realmSeeding` blocks carry `recoveryExistingRevision`,
`recoveryExistingRevisions`, `recoveryPreserveExistingJobs`, `recoveryImageByRevision`. These do not
appear to be upstream tractus-x 4.2.1 fields and look like local edits to a vendored chart. If so these
`.tgz` files are not reproducible from upstream, which matters for pinning. `[INFERRED]` — Payam to
confirm from history.

**`arena` client scope — Phase 3 blocker.** `Provisioning:CentralOIDCClient:defaultClientScopes` is
`["arena", "web-origins", "roles", "profile", "email"]`. When the Portal creates a company's OIDC
client it assigns a scope named `arena` — an ARENA2036 name in a Catena-X realm. Either someone added
it to his realm for us (one more thing of ours in his environment) or client creation has been
failing. Our fresh `CX-Central` will not have it from the stock seed. **This would fail in Phase 9,
after the switch — the worst place to discover it.** Resolve before writing any values file.

### 4.6 Environment

**DNS — [PENDING VERIFICATION]. The v3 conclusion was wrong.**

Observed: `centralidp-be293`, `sharedidp-be293`, `issuer-be293`, `identityhub-be293` all resolve to
nothing, including a randomly generated name that never existed, and including against `@8.8.8.8`.
`portal-be293` resolves to `188.34.116.149`.

v3 concluded from this that no wildcard exists and that Saud must create four records. **That
conclusion does not follow.** `be293-portal-frontend` carries
`external-dns.alpha.kubernetes.io/hostname: portal-be293.test.tractus-x.com` alongside
`cert-manager.io/cluster-issuer: letsencrypt-prod`, which indicates records are created **from the
Ingress** by ExternalDNS. A name not resolving before its Ingress exists is then the expected state,
not evidence of a missing capability.

**Not yet verified**: that an ExternalDNS controller is actually deployed and reconciling on Alpha.
The annotation proves intent, not that anything acts on it. Verify before Phase 5 depends on it:

```bash
K get deploy,pods -A | grep -i external-dns
K logs -n <ns> deploy/<external-dns> --tail=50 | grep -i -E "portal-be293|record|zone"
```

Until that comes back positive, treat automatic record creation as **unconfirmed** and keep asking
Saud for records as a fallback. If it is confirmed, no DNS request to Saud is needed at all and the
four names are created by declaring them in our own Ingress annotations.

**Portal database.** The Portal runs in the **default `postgres` database**, schema `portal`, user
`portal` (`Server=be293-portal-postgresql; Database=postgres; Port=5432; User Id=portal`). Tables
confirmed: `iam_clients`, `iam_identity_providers` (`iam_idp_alias`, `identity_provider_id`,
`metadata_url`), `identity_providers`, `companies` (`business_partner_number`). `metadata_url` is
empty for shared IdPs — the Portal derives the URL from the sharedidp address.

**This constrains D4:** a "clean re-seed" cannot be a database drop and must be a schema-level
operation. Using the default `postgres` database is poor practice — it muddles ownership and
complicates `pg_dump`/restore — and it also affects the Phase 11 backup drill. Not urgent, but
recorded.

**Persistence is working here.** PVC `data-be293-portal-postgresql-0` bound 2026-11-05, pod restarted
2026-11-12 — it survived the node event that destroyed the in-memory Vaults.

**Worker suspended 2026-11-13.** Was `*/5 * * * *`, `suspend=false` — writing into `release26-09` on a
five-minute loop. Now `suspend=true`. **Reverse with `suspend=false` only after the switch.**

### 4.7 Carried over from v1/v2 (do not re-investigate)

- **Incident 2026-11-12:** all four Vaults in `release26-09` run `Storage Type: inmem`; a node event at
  ~01:50 UTC lost key material. IssuerService super-user key → 401; IdentityHub 01 → 500 (`NPE` in
  `ParticipantServicePrincipalResolver`). Saud confirmed no recovery procedure.
- **BPN credential root cause:** Portal registers holders with `holderId = BPN`; the shared issuer's
  `BpnCredential-id` uses a `database` attestation on `custom_attestation_claims` (DID-keyed rows only)
  → no row → `success(null)` → `putAll(null)` NPE → 500.
- **Proven DEV pattern:** `holders-database-attestation` (database, datasource `holder`, table
  `holders`) + `holder-properties-attestation` (type `holder`); `tx-bpncredential` mappings
  `did → credentialSubject.id`, `holder_id → credentialSubject.holderIdentifier`,
  `holder_id → credentialSubject.bpn`. DEV Membership has **no** `memberOf` and is not a valid template.
- **Known Worker defects:** deterministic `BuildHolderPid`; no holder update on 409;
  `BPNL000000000342` falsely `BPNL_CREDENTIAL = DONE`.
- **Images confirmed pullable:** `tractusx/issuerservice:0.4.1`, `tractusx/identityhub:0.4.1`.
- **IdentityHub 0.17.0** admin API uses the **plain** participant id, not base64.

---

## 5. Gate 0 — what is still open

- [ ] **David approves** building an own IAM and identity stack in `be293`, accepting §2's limits.
- [ ] **D2 — ExternalDNS verified on Alpha** (§4.6). Ours to check, not Saud's. If it is not running,
      DNS records become a request to whoever owns the zone and Phase 5 waits on them.
- [ ] **D3 — sent to Saud**, awaiting reply, two questions only: is keeping `sa-cl7-cx-5` acceptable
      (and will he warn us before rotating it); who removes the four aliases in §4.4, and when.
      Optional third: does `CX-Central` have an `arena` client scope (§4.5)?
- [ ] **D4 — Portal state.** Clean re-seed of the `portal` schema alongside the new realms, or keep the
      database and clean stale `iam_*` rows. Recommendation: **clean re-seed**, with a verified
      `pg_dump` stored first. Constrained by §4.6 — schema-level, not a database drop.
- [ ] **D5 — SharedIDP SMTP.** We own the mail configuration now. Recommendation: point it at the
      existing `smtp4dev` sink so test invitations cannot reach real external addresses. Office 365
      only if real delivery is a stated acceptance requirement.
- [ ] **D6 — Membership semantics** (`memberOf` source, e.g. constant `Catena-X` for approved companies).
**Closed:** D1 (§4.1), BDRS (§4.3, Payam 2026-11-13).
**Removed:** D7 (BPN reassignment) — existed only to serve the own-BPDM phase, which is gone.

---

## 6. Roadmap

### Phase 1 — read-only discovery (**partially complete**)

Done: §4.1–§4.6. Remaining, best run in Claude Code (bulk file reading):

1. Both realm-seeding jobs: realm names, clients, technical service accounts, roles, operator admin
   user, redirect/web-origin/frontend-URL values, SMTP block, password policy.
2. **The `arena` client scope** (§4.5) — does the stock seed create it? If not, what must we add?
3. Appendix A, filled from the portal chart and `values-be293-portal.yaml` with `file:line` evidence.
4. Full `portal` schema dump — every table and column binding to Keycloak identifiers. Feeds D4.
5. **Item 13:** does anything trigger the `DELETE_*_IDENTITY_PROVIDER` chain on a failed invitation?
6. Worker: every path that sets `BPNL_CREDENTIAL = DONE`; the false `DONE` on `0342`; the commit the
   2026-11-07 image was built from.
7. Worker: caller of `RequestCredentialAsync`, and which values are in scope at the call site.
8. `bdrs-server` 0.6.0: chart contents, API key, PostgreSQL, the two Portal settings that repoint.
9. DEV blueprint: `identity-and-trust-bundle` and its seed job.
10. Chart provenance (§4.5) — are the `recovery*` fields local edits?

Output: `docs/dev/BE-293-phase1-discovery-report.md`. **STOP — Gate 1.**

### Phase 2 — ADR (≈ 1 day)

`docs/dev/BE-293-alpha-iam-and-identity-adr.md`, covering both stacks plus BDRS. Keycloak production
mode and explicit proxy headers; public Ingress serving only browser-flow endpoints with the admin API
blocked by rule; generated secrets via `existingSecret`; idempotent fail-closed seeding; unique IdP
aliases; SMTP per D5; default-deny NetworkPolicies; Vault with Raft on a PVC, Kubernetes auth,
least-privilege policies, documented unseal-key handling and snapshots; PostgreSQL per service;
issuer DID `did:web:issuer-be293.test.tractus-x.com`; holder DIDs under
`did:web:identityhub-be293.test.tractus-x.com:<BPN>`; the DEV issuance pattern with an `expression`
rule on `approvalSource = portal-be293`; scoped API keys only. Document the D1 exception precisely.
**STOP — Gate 2.**

### Phase 3 — charts and values, local only (≈ 2–2.5 days)

`be293-iam` (CentralIDP + SharedIDP + their PostgreSQL), `be293-identity` (Vault, IssuerService,
IdentityHub, BDRS, PostgreSQL), and the Portal rewiring overlay — prepared, not applied. Digest-pinned
images, PVCs, probes, resources, non-root, NetworkPolicies, `secrets-contract.yaml`,
`expected-inventory`, offline gates, Ruby tests. Verify with `helm lint`, `helm template` + schema
validation, policy check, seed-script unit tests, and a grep gate proving no secret literal entered
Git. **STOP — Gate 3.**

### Phase 4 — Worker changes, local only (≈ 1 day)

`HolderProperties` gains `bpn`, `approvalSource`, `applicationId`, `approvedAt`; `PUT` holder on 409;
new unique request id per retry after terminal failure; secret-free failure reasons; fix the false
`DONE`. Unit tests, full suite, recorded results. **STOP — Gate 4.** Image build and push via the
retrigger-images workflow only after approval; digest recorded.

### Phase 5 — deploy `be293-iam` (live, ≈ 1 day)

Secrets and NetworkPolicies → PostgreSQL for both Keycloaks with a restart test → CentralIDP and
SharedIDP → realm seeding → **verify the issuer in a real token is the public HTTPS URL**, and that
`/.well-known/openid-configuration` is public while the admin API is not → full restart test.
**STOP — Gate 5.**

**Ingress and TLS sequencing** (applies to Phase 7 too). Each name: apply the Ingress with its
`external-dns.alpha.kubernetes.io/hostname` annotation → wait for the record to appear and propagate →
*then* let cert-manager run its HTTP-01 challenge → verify TLS. Several minutes, not instant; an early
challenge failure while DNS propagates is expected, not a fault.

**`letsencrypt-prod` is production.** Real rate limits apply (5 duplicate-certificate failures per
week per name). Get each Ingress right in `helm template` before applying, and iterate on a throwaway
name rather than `centralidp-be293` — locking ourselves out of a name costs days.

### Phase 6 — switch the Portal to our IAM (live)

`pg_dump` verified restorable → back up values and Secret metadata → apply the overlay → D4 action →
verify login, token `iss` and `aud`, and that **no request reaches the shared Keycloak except the
documented BPDM exception**. **STOP — Gate 6.**

### Phase 7 — deploy `be293-identity` incl. BDRS (live, ≈ 1–1.5 days)

Secrets and NetworkPolicies → Vault (init, unseal, auth, policies; restart test) → PostgreSQL (restart
test) → IssuerService, IdentityHub, BDRS → seed job → Ingress and TLS, DID documents public over HTTPS,
admin APIs not public → full restart test. **STOP — Gate 7.**

### Phase 8 — switch the Worker (live)

New scoped keys; update `APPLICATIONCHECKLIST__IDENTITYHUB__*` and `BPNDIDRESOLVER__*`; deploy the
Phase 4 image by digest; verify with read-only calls. **Un-suspend the CronJob here, not before.**
**STOP — Gate 8.**

### Phase 9 — onboard the three companies once

Through supported Portal flows only. Invitation → realm and IdP in **ours** with unique aliases →
company admin logs in → wallet, DID, BPN and Membership credentials → `APPLICATION_ACTIVATION` `DONE`.
**STOP — Gate 9.**

### Phase 10 — acceptance

| # | Test | Expected |
|---|---|---|
| A1 | Approved onboarding | All credential steps `DONE` |
| A2 | Credential content | `credentialSubject.id` = holder DID, `bpn` = BPN, issuer = new issuer DID, valid signature, status list resolvable |
| A3 | Unapproved holder | No credential, clear failure, no 500 |
| A4 | Restart resilience | Delete every pod of both stacks; repeat A1 and A9 |
| A5 | Retry after failure | New request id, succeeds |
| A6 | Exposure (identity) | Admin APIs unreachable externally; DID and status list reachable |
| A7 | Secret hygiene | No secrets in logs, Git, values or manifests |
| A8 | Final checks | Tests, lint, security scan after the last edit, with SHAs and timestamps |
| A9 | Portal login | Operator and company admin log in via our SharedIDP; token `iss` is our public HTTPS URL |
| A10 | Invitation (A07 regression) | Uniquely aliased IdP, no collision, mail at the configured sink |
| A11 | Activation | `APPLICATION_ACTIVATION` `DONE` — the `0342` 401 does not recur |
| **A12** | **Isolation** | **Zero writes into `release26-09`.** Evidence from configuration and NetworkPolicy, not assumption. Only documented traffic: BPDM on the public testbed. |
| A13 | IAM exposure | Keycloak admin API and console not reachable externally; realm endpoints are |
| A14 | No default secrets | No seeded placeholder or default admin credential accepted |
| **A15** | **Failed-onboarding leak** | Deliberate mid-flow failure; record exactly what identity objects remain (§4.4) |

### Phase 11 — operations, handover, decommission

Backup/restore drill across Vault, both Keycloak databases, the Portal schema, issuer, IdentityHub and
BDRS from one recovery point. Runbooks: Vault unseal, Keycloak realm backup/restore, key and secret
rotation, credential revocation, node-event recovery. Update the Alpha handover. Hand Saud the §4.4
list for removal — **we do not touch it**.

---

## 7. BPDM — unchanged, out of scope

The Portal continues to use the public BPDM testbed at `business-partners.test.tractus-x.com` via
`sa-cl7-cx-5` (`client_credentials`, §4.1). BPDM is **not** in `release26-09`, so the read-only rule
does not reach it, and nothing in Saud's request concerns it.

No work is planned here. v3 proposed an own-BPDM phase; that was scope expansion on an assumption and
has been removed.

Recorded only so the option is findable if a demonstrated technical reason ever appears:
`bpdm-6.2.0` is in the pinned umbrella and our centralidp seed already creates the `bpdm`, `bpdmGate`
and `bpdmOrchestrator` clients. The cost would be a fresh pool minting new BPNs for our three
companies, since our identity stack keys holders, DIDs and credentials on BPN. **Do not act on this
paragraph without a stated reason and approval.**

---

## 8. Effort

~9–11 working days to Gate 10 (BDRS adds ~1 day over v2), plus review time at each gate and whatever
lead time Saud's DNS records take. The deferred BPDM phase is a further 2–3 days if taken.

---

## 9. Claude Code kickoff (v3)

```text
Read docs/dev/BE-293-alpha-portal-test-replica-roadmap-v4.md completely.
Follow section 3 (rules) strictly — note especially: release26-09 is READ-ONLY, no writes.

SCOPE DISCIPLINE (section 2.1). Saud asked for ONE thing: separate CentralIDP and SharedIDP.
Everything else in scope is our own decision with a stated reason. BPDM is explicitly OUT of
scope and stays on the public testbed. Do not propose rebuilding, replicating or
re-architecting any component that section 2.1 does not already list. If you believe
something else needs to change, say so as a question for Payam — do not plan it.

Gate 0 is [PASSED / NOT PASSED — set by me]. Phase 1 is PARTIALLY COMPLETE.

Section 4 records what is already proven. Do NOT re-investigate it. In particular:
  - D1 is DECIDED (option a, proven in source — section 4.1). Do not re-open it.
  - BDRS is DECIDED by Payam: own bdrs-server 0.6.0, postgres-backed (section 4.3). Do not
    re-evaluate whether to keep it shared — the read-only rule forbids that.
  - The Portal schema lives in the DEFAULT `postgres` database, schema `portal` (section 4.6).
  - The processes worker CronJob is SUSPENDED. Do not un-suspend it.

Do the REMAINING Phase 1 items listed in section 6, items 1-10. Highest priority:
item 2 (the `arena` client scope) and item 5 (does anything clean up a failed invitation?)
— both would fail late, after the switch, if we get them wrong.

You may read:
  - ~/Projects/ARENA2036/BE293_ALPHA/tx-umbrella (incl. handoff/ and alpha/portal-release-prepared)
  - ~/Projects/ARENA2036/portal-backend-await-fix
  - ~/Projects/ARENA2036/BE293_ALPHA/tx-umbrella-retrigger-images
  - ~/Backup/Projects/public-tractus-x-umbrella (DEV blueprint, reference only)
  - Alpha namespaces be293 and release26-09, READ-ONLY, always with
    --kubeconfig ~/.kube/alpha.yaml --context alpha

Do not modify any file, branch, cluster resource or Git state. Do not print secrets.
Report each item as: finding, evidence (file:line, command + relevant output), confirmed or inferred.
Write docs/dev/BE-293-phase1-discovery-report.md, then stop and wait for my review (Gate 1).
```

---

## Appendix A — Portal IDP configuration surface (to be filled)

| Area | What to find | Current | Target | Evidence |
|---|---|---|---|---|
| Portal values | CentralIDP address | `centralidp.test.tractus-x.com` | `centralidp-be293.test.tractus-x.com` | |
| Portal values | SharedIDP address | shared | `sharedidp-be293.test.tractus-x.com` | |
| Frontend | SSO/authority URL, realm, client id | | | |
| Frontend | redirect URIs / web origins in the seeded client | | | |
| Backend (all) | JWT authority / metadata address | | | |
| Backend (all) | valid issuer, valid audience | | | |
| Backend | `Keycloak:central` — address, realm, client, secret | | | |
| Backend | `Keycloak:shared` — address, realm, client, secret | | | |
| Registration / Administration | IDP settings, IdP alias prefix | | | |
| Processes worker | IDP settings | | | |
| **Outbound: BPDM** | token endpoint, client, secret | shared CentralIDP | **unchanged (D1a)** | §4.1 |
| Outbound: SD Factory / Clearing House / Dim | token endpoint, client, secret | | per section | |
| **BDRS** | `BPNDIDRESOLVER__BASEADDRESS`, API key | `release26-09` | `be293` | §4.3 |
| IdentityHub / IssuerService | `APPLICATIONCHECKLIST__IDENTITYHUB__*` | `release26-09` | `be293` | §4.3 |
| Kubernetes Secrets | every key holding an IDP client secret | | | |
| NetworkPolicy | egress rules referencing Keycloak and `release26-09` | | | |
