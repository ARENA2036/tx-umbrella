# BE-293 Alpha — Portal Test Replica in `be293`: Roadmap v5

**Date:** 2026-11-16
**Supersedes:** v4 (2026-11-13), v3, v2 (2026-11-13), v1 (2026-11-12)
**Owner:** Payam (BE-293) · Decision: David Görzig · Coordination: Saud Khan
**Status:** Plan. **Gate 0 NOT PASSED.** Phase 1 offline work complete; **Gate 1 passed 2026-11-16 with two
caveats** (§0). Cluster-dependent Phase 1 reads are carried as Phase 1b (§6).
**Evidence:** `docs/dev/BE-293-phase1-discovery-report.md` (referred to below as *the report*).

**Purpose:** build a replica in `be293` to test the new BE-293 Portal and its components safely on the
Alpha cluster, isolating only the components that must be isolated. If it works, Saud changes the
shared environment over to the new Portal. Nothing here is a permanent parallel platform.

---

## 0. What changed in v5

v5 records the result of Phase 1 (offline) and the decisions taken at Gate 1. **Scope is unchanged:** no new
component, and no resolved decision reopened.

**Gate 1 — passed 2026-11-16 (Payam), with two caveats:**
1. *Approximate citations in the report.* Corrected in the report (revision 2026-11-16). **Closed.**
2. *Unverified chart provenance.* The pinned `bdrs-server-0.6.0.tgz` differs from the published digest and was
   never content-compared. The IDP forks are compared only against a copy that is inferred to be upstream.
   **Carried into Phase 3** (P3-4).

**Decisions taken at Gate 1:**

| # | Decision | Where |
|---|---|---|
| G1-1 | **BPDM and SD Factory authentication stay on the existing shared CentralIDP** (`sa-cl7-cx-5`, `sa-cl8-cx-1`). This extends the D1 exception to SD Factory; D1 itself is unchanged. | §4.1 |
| G1-2 | **Keep the existing chart forks** (centralidp, sharedidp, portal, bdrs-server). Pin by digest; keep the recovery settings explicitly disabled and enforce that with a test. | §4.5, P3-3 |
| G1-3 | **BDRS chart comparison** against the published 0.6.0 is a Phase 3 deliverable. | P3-4 |
| G1-4 | **Admin keys** for IdentityHub/IssuerService are provisioned without relying on pod logs. | §4.9 |

| | v4 | v5 |
|---|---|---|
| Phase 1 | partially complete | offline items done (report); cluster reads → **Phase 1b** |
| D1 | decided (a), no code change | unchanged; **implementation needs a Portal chart patch** — the chart derives outbound token endpoints from `centralidp.address` (§4.1) |
| SD Factory auth | not mentioned | **stays on shared CentralIDP** (G1-1) |
| `arena` scope | "Phase 3 blocker", cause unknown | **cause known** (Portal commit `43767079b`); affects offer clients only; fix must live in the seed or the Portal config; **choice in Phase 2 ADR** (§4.5) |
| Failed-invitation cleanup | unknown (item 13) | **answered: nothing automatic**; orphans of steps 1–8 are invisible to every deletion path (§4.4) |
| Chart provenance | open question | **confirmed local forks**; kept, digest-pinned, recovery disabled (G1-2) |
| BDRS | own, PostgreSQL | unchanged; **also needs its own Vault**; 4 more Portal references + 1 NetworkPolicy to repoint (§4.3) |
| Admin keys | — | **log-free provisioning** required (§4.9) |
| A15 | one mid-flow failure | **two failure points** (§6 Phase 10) |

### v3 → v4 (retained for history)

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
4a. **SD Factory authentication is unchanged** (G1-1). `sa-cl8-cx-1` stays in the shared CentralIDP. With
   `clearinghouseConnectDisabled: true` the self-description step is `SKIPPED` and SD Factory is not called
   (report, item 3 note ¹). Turning it on would mean calls into `release26-09`, which needs a separate
   decision.
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
the shared BPDM pool, unchanged (§2.1 C). Machine tokens for BPDM (and SD Factory, if it is ever enabled)
continue to come from the shared CentralIDP (G1-1).

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
| Keys | No super-user keys in the Portal. Scoped keys only. **No key is ever obtained from pod logs**, and no job gets `pods/log` (§4.9). |
| Seeded IAM objects | Anything we need in a seeded realm (client scopes, clients) lives **in the seed**. The seeding jobs run on every Helm revision with `DELETE=true` and remove hand-made client scopes (§4.5). |
| Chart forks | Digest-pinned; recovery values explicitly empty; never render with `recoveryPreserveExistingJobs: true` (§4.5). |
| Git | Preserve uncommitted work. No push or PR without approval. **No AI attribution anywhere** — commits, PR titles and descriptions, comments, release notes, docs, source. Use the existing Git identity. |
| Evidence | Distinguish observed, prepared, deployed and verified. Never claim an unproduced result. |
| Conventions | Follow `alpha/portal-release-prepared`: `values-be293-*.yaml`, `images.lock.yaml`, `secrets-contract.yaml` (key names only), `expected-inventory*.txt`, offline gates in `tools/render-release.sh`, Ruby tests under `tests/`. |
| Shell | zsh. `setopt interactive_comments`, quote every glob, `K` is a function not a variable. |

---

## 4. Confirmed findings

Everything in §4.1–§4.6 was observed on 2026-11-13 with evidence. Paragraphs marked **v5** were added from
the offline Phase 1 pass (the report, 2026-11-16). `[INFERRED]` marks anything that is reasoning rather than
observation.

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

**v5 — SD Factory (G1-1).** `sa-cl8-cx-1` also stays in the shared CentralIDP, on the same terms. SD Factory
is not called while `clearinghouseConnectDisabled: true`.

**v5 — implementation consequence (D1 not reopened).** The Portal **chart** does not keep the token endpoints
separate. It builds these from the single value `centralidp.address` + `backend.keycloak.central.tokenPath`:
- `APPLICATIONCHECKLIST__{BPDM,SDFACTORY,CUSTODIAN,ISSUERCOMPONENT}__TOKENADDRESS`
- `OFFERPROVIDER__TOKENADDRESS`
- `SERVICEACCOUNT__AUTHSERVICEURL`
- `APPLICATIONCHECKLIST__DIM__TOKENADDRESS` (administration)

Evidence: report item 3, e.g. `portal-2.6.0.tgz!templates/cronjob-backend-processes.yaml:146-147,242-243`,
`deployment-backend-administration.yaml:120-121,216-217`.

Pointing `centralidp.address` at ours would therefore also move BPDM to our IdP and break it. Phase 3 adds a
patch to the (already forked) Portal chart. It gives the BPDM and SD Factory token addresses their own
values, which default to `centralidp.address` so existing renders do not change (P3-1).

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

**v5 — what "own BDRS" contains (report item 8).**
- **BDRS needs a Vault.** The DB user/password and the management API key are read from Vault aliases
  (`edc.datasource.didentry.user|password`, `authKeyAlias`). The chart defaults are a dev-mode Vault with
  root token `root` and **Postgres persistence off**.
- **`server.trustedIssuers` must not be empty.** It must name our issuer DID.
- **The pattern already exists** in the pinned umbrella (`be293Provisioning`):
  - a Raft-storage Vault on a PVC, used only by BDRS;
  - a non-root init container that writes the three aliases from mounted Secrets, write-once;
  - a NetworkPolicy so that only BDRS reaches that Vault.

  We reuse it. We do **not** reuse two things from the DEV overlay: a public `management` Ingress and a
  static Vault token.
- **Repointing touches more than two settings.** Four further Portal settings use the BDRS **directory** URL:
  - `SERVICES__BPNDIDRESOLVERURL`
  - `COMPANYDATA__BPNDIDRESOLVERURL`
  - `APPMARKETPLACE__BPNDIDRESOLVERURL`
  - frontend `BPNDIDRESOLVER_DIRECTORY_URL`

  The BDRS rule in `be293-portal-release26-09-egress` must also go. Whether the directory references move to
  our BDRS is a Phase 2 ADR point (they are reads, so the read-only rule is not affected).
- **Chart provenance:** the pinned `bdrs-server-0.6.0.tgz` differs from the published digest and was never
  content-compared. See P3-4.

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

**v5 — answered (report item 5, CONFIRMED). Nothing triggers it.**

- **Only one trigger.** The chain is created only by the applicant's own decline
  (`Registration.Service … RegistrationBusinessLogic.cs:913-940`, `:974-1015`). That needs a logged-in
  applicant.
- **Failure handling.** A failed invitation step only schedules a manual `RETRIGGER_INVITATION_*`
  (`InvitationProcessTypeExecutor.cs:111-151`, `InvitationProcessStepTypeIdExtensions.cs:27-41`).
- **The early-creation wording above needs a correction.** Within the invitation, Keycloak objects are
  created in steps 1–8. The Portal's `identity_providers` / `iam_identity_providers` rows are written only at
  **step 9** (`InvitationProcessService.cs:260-280`).
- **Every deletion path reads those rows.** So the objects of a failure in steps 1–8 can be found by **no**
  deletion path. Their only trace is `company_invitations.idp_name`.
- **Consequence.** Manual cleanup is the accepted mechanism. There is no Portal code change (§2.1).
  - Phase 6 adds an orphan inventory before the D4 re-seed.
  - Phase 10 A15 tests two failure points.
  - Phase 11 adds a cleanup runbook keyed on `idp_name` and the Keycloak alias list.

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

**v5 — confirmed and decided (report item 10; G1-2).**
- *Confirmed.* `recovery/be293-dev-3.17.0/VALIDATION.md:77` (in `tx-umbrella-0.13-integration`) records
  centralidp 4.2.1, sharedidp 4.2.1, portal 2.6.0 and bpdm 6.2.0 as *"Locally modified forks of the published
  releases"*. Line 78 records bdrs-server 0.6.0 as *"Differ from the published digests. Content was not
  compared"*.
- *Decided: keep the forks.* Requirements:
  - pin each `.tgz` by sha256 in `images.lock.yaml` (or a sibling `charts.lock`);
  - set `realmSeeding.recoveryExistingRevision: ""`, `recoveryExistingRevisions: []`,
    `recoveryPreserveExistingJobs: false` and `recoveryImageByRevision: {}` **explicitly** in our values;
  - add an offline gate that fails the render if any of them is non-empty or `true`, or if the rendered seed
    Job contains a copied spec (P3-3).

  Reason: with `recoveryPreserveExistingJobs: true` the template copies a **live** Job spec through
  `lookup`, so an offline render no longer describes what is applied.

**`arena` client scope — Phase 3 blocker.** `Provisioning:CentralOIDCClient:defaultClientScopes` is
`["arena", "web-origins", "roles", "profile", "email"]`. When the Portal creates a company's OIDC
client it assigns a scope named `arena` — an ARENA2036 name in a Catena-X realm. Either someone added
it to his realm for us (one more thing of ours in his environment) or client creation has been
failing. Our fresh `CX-Central` will not have it from the stock seed. **This would fail in Phase 9,
after the switch — the worst place to discover it.** Resolve before writing any values file.

**v5 — cause found; re-scoped (report item 2 and Addendum A).**
- *Cause.* Upstream uses `catena`. Portal commit `43767079b` ("chore:ARENA branding") bulk-renamed it to
  `arena` in three `appsettings.json` files. The rename is in every deployed image, and the chart has no env
  hook for this setting.
- *Scope.* `CentralOIDCClient` is used only for **marketplace offer clients** (`OfferSetupService`). It is
  **not** used by invitation, onboarding or activation. So this does not block Phase 9 login or onboarding;
  it affects app/service offers.
- *Keycloak's reaction.* Most likely the unknown scope is silently ignored, so offer clients lack the
  `bpn`/`organisation` claims. `[INFERRED]`
- *A hand-added scope will not survive.* The CX-Central seed runs with `DELETE=true` on every Helm revision
  and deletes client scopes that are not in the seed.
- **Choice for the Phase 2 ADR** (not decided here):
  - (a) add an `arena` scope (same mappers as `catena`) to **our** CX-Central seed;
  - (b) restore `catena` in the Portal configuration.
- *Same defect class.* The audit of the commit found four wire-level renames in total: W1 open, W2 fixed in
  `e2451f876`, W3 no consumer, W4 not on the IdentityHub path. Nothing else reaches an external contract.

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

### 4.8 v5 — other Phase 1 results that shape later phases

- **Seeding re-runs.** The realm-seeding Job is named per Helm revision, so it runs on **every** upgrade.
  `CX-Central` and `CX-Operator` seed with `CREATE/UPDATE/DELETE=true`. `master` is restricted to the
  `sa-cl1-reg-1` and `saCX-Operator` clients (report item 1).
- **CX-Central seed source.** The umbrella replaces the stock realm image with
  `umbrella-init-container:2.3.0-init`, built from this repo's `init-container/`. That image includes 16
  `satest*` test service accounts. Which seed image we use is a Phase 2 ADR point.
- **Not seeded.** `frontendUrl` and a password policy are not seeded in CX-Central. The A9 issuer depends
  only on Keycloak hostname/proxy configuration (§4.5).
- **sharedidp initial user.** The CX-Operator initial user's password defaults to a published value when
  unset (values comment: `"!3changemeTractus-X"`). The Secret must always supply it (A14).
- **Values in scope for Phase 4.** At the `RequestCredentialAsync` call site only BPN, credential type and
  definition id are in scope. The application id exists one level up; the approval time exists nowhere on
  the path. Phase 4 must thread them through `IIssuerComponentService` (report item 7).
- **NetworkPolicy limit.** Our new Keycloak hosts will probably share the ingress address
  `188.34.116.149/32` with his Keycloak. If so, NetworkPolicy alone cannot prove A12 for Keycloak traffic;
  configuration and traffic evidence must do it. `[INFERRED]`

### 4.9 v5 — Admin-key provisioning without pod logs (G1-4)

**Problem (report item 9, CONFIRMED in source).**
- The DEV seed job gets the IdentityHub/IssuerService super-user keys by **grepping pod logs**. Its
  fallbacks are `--previous` logs, then a Vault read-back.
- `SuperUserSeedExtension` logs the key at INFO on first creation **even when it is preset**
  (`…/SuperUserSeedExtension.java:103`).
- The key can be preset through `edc.ih.api.superuser.key` (`:46-47`). The required format is
  `base64(<participantId>).<random>` (`:93`). The extension acts only when the super-user does not yet exist
  (`:75`).

**Design (to be confirmed in the Phase 2 ADR; implemented in Phase 3 and Phase 7):**

1. **Generate, don't discover.** A one-off approved step generates each bootstrap key directly into a
   Kubernetes Secret in `be293`. The value is never echoed, never on a command line, never in Git or values.
   Format as required above. `secrets-contract.yaml` lists key names only.
2. **Inject by reference.** IdentityHub receives it as `EDC_IH_API_SUPERUSER_KEY` through
   `envValueFrom.secretKeyRef`.
   - *To verify in Phase 2:* the IssuerService property name, and that the EDC env-to-setting mapping
     applies to it.
3. **Make the logged value useless.** The first-boot log line still contains the bootstrap key. Immediately
   after first boot, the seed job **rotates** the super-user key through the admin API and writes the new key
   straight into the Secret. To do that, the job is allowed `get`/`update` on that one Secret
   (`resourceNames`). From then on, the key in the log is invalid.
   - *To verify in Phase 2:* the IdentityHub/IssuerService endpoint that regenerates a participant's API key.
   - *If no such endpoint exists:* set the logger's level so INFO is not emitted for that first boot, and
     treat the first-boot container log as secret material (no log shipping) until it rotates out.
     Recorded as a fallback, not preferred.
4. **Seed job hygiene.** Copy the existing `be293-bdrs-vault-provision.sh` style:
   - read keys from mounted Secret files;
   - pass headers through a `curl --config` file in a memory `emptyDir`;
   - no `set -x`, no echo of values;
   - non-root, read-only root filesystem;
   - **no `pods/log` permission** in any Role.
5. **The Portal never holds a super-user key** (§3). It gets the scoped keys that the seed job creates for
   it, through the existing `be293-portal-identityhub` Secret.
6. **Acceptance (adds to A7/A14):**
   - after rotation, a request with the bootstrap key gets `401`;
   - a search of every pod log in `be293` for each current key value finds nothing (checked inside the
     cluster, never printing the value);
   - no Role in `be293` grants `pods/log`.

### 4.10 v5 — Phase 1 items still open (cluster-dependent → Phase 1b)

- Full `portal` schema dump. This needs approval for `pods/exec`.
- The `company_invitations.idp_name` orphan inventory (query in the report, item 4).
- `iam_clients` rows.
- Live env of the Portal Deployments and CronJob compared with the prepared values.
- Step history and Helm revision for the false `DONE` on `0342`.
- D2 (ExternalDNS).
- `CX-Operator` and `master` realm JSON from `tractusx/portal-iam:v4.2.0`. This needs an image pull.

---

## 5. Gate 0 — what is still open

- [ ] **David approves** building an own IAM and identity stack in `be293`, accepting §2's limits.
- [ ] **D2 — ExternalDNS verified on Alpha** (§4.6). Ours to check, not Saud's. If it is not running,
      DNS records become a request to whoever owns the zone and Phase 5 waits on them.
- [ ] **D3 — sent to Saud**, awaiting reply, two questions only: is keeping `sa-cl7-cx-5` acceptable
      (and will he warn us before rotating it); who removes the four aliases in §4.4, and when.
      Optional third: does `CX-Central` have an `arena` client scope (§4.5)? *(v5: informational only. The
      cause is known, and our fix does not depend on the answer.)*
- [ ] **D4 — Portal state.** Clean re-seed of the `portal` schema alongside the new realms, or keep the
      database and clean stale `iam_*` rows. Recommendation: **clean re-seed**, with a verified
      `pg_dump` stored first. Constrained by §4.6 — schema-level, not a database drop.
      *(v5: run the `idp_name` orphan inventory (Phase 1b) before either option — a re-seed destroys the
      only record of those aliases, §4.4.)*
- [ ] **D5 — SharedIDP SMTP.** We own the mail configuration now. Recommendation: point it at the
      existing `smtp4dev` sink so test invitations cannot reach real external addresses. Office 365
      only if real delivery is a stated acceptance requirement.
- [ ] **D6 — Membership semantics** (`memberOf` source, e.g. constant `Catena-X` for approved companies).
      *(v5: the Portal currently hard-codes `"arena-x"`, and the IdentityHub path does not send it —
      report Addendum A, W4.)*
**Closed:** D1 (§4.1), BDRS (§4.3, Payam 2026-11-13), G1-1 to G1-4 (§0, Payam 2026-11-16).
**Gate 1:** passed 2026-11-16 with two caveats (§0). **Gate 0 remains NOT PASSED.**
**Removed:** D7 (BPN reassignment) — existed only to serve the own-BPDM phase, which is gone.

---

## 6. Roadmap

### Phase 1 — read-only discovery (**offline items complete; Gate 1 passed 2026-11-16**)

Done: §4.1–§4.6, plus items 1, 2, 3, 5, 6, 7, 8, 9 and 10 below (the report). Item 4 and the
cluster-dependent parts of items 2, 3 and 6 move to Phase 1b. Original list, for reference:

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

Output: `docs/dev/BE-293-phase1-discovery-report.md`. **STOP — Gate 1.** *(Passed 2026-11-16.)*

### Phase 1b — cluster-dependent reads (read-only, when Alpha access is restored)

Run the items in §4.10 with the guarded `K` function and read verbs only. The schema dump and orphan
inventory use `pods/exec`, so they need separate approval first. Append the results to the report as a
dated revision. Phase 1b must be complete **before Phase 6** (D4 needs the schema and the orphan
inventory). It is not a prerequisite for Phase 2 or Phase 3.

### Phase 2 — ADR (≈ 1 day)

`docs/dev/BE-293-alpha-iam-and-identity-adr.md`, covering both stacks plus BDRS. Keycloak production
mode and explicit proxy headers; public Ingress serving only browser-flow endpoints with the admin API
blocked by rule; generated secrets via `existingSecret`; idempotent fail-closed seeding; unique IdP
aliases; SMTP per D5; default-deny NetworkPolicies; Vault with Raft on a PVC, Kubernetes auth,
least-privilege policies, documented unseal-key handling and snapshots; PostgreSQL per service;
issuer DID `did:web:issuer-be293.test.tractus-x.com`; holder DIDs under
`did:web:identityhub-be293.test.tractus-x.com:<BPN>`; the DEV issuance pattern with an `expression`
rule on `approvalSource = portal-be293`; scoped API keys only. Document the D1 exception precisely.

**v5 — the ADR must also settle these:**
- `arena`: option (a) or (b) (§4.5);
- the CX-Central seed image: umbrella init container with `satest*`, or stock (§4.8);
- the BDRS directory references and BDRS's own Vault (§4.3);
- admin-key provisioning, including the two verification points (§4.9);
- the chart-fork policy (G1-2);
- manual failed-invitation cleanup as the accepted mechanism (§4.4);
- the D1/SD Factory exception expressed as a chart patch (§4.1).

**STOP — Gate 2.**

### Phase 3 — charts and values, local only (≈ 2–2.5 days)

`be293-iam` (CentralIDP + SharedIDP + their PostgreSQL), `be293-identity` (Vault, IssuerService,
IdentityHub, BDRS, PostgreSQL), and the Portal rewiring overlay — prepared, not applied. Digest-pinned
images, PVCs, probes, resources, non-root, NetworkPolicies, `secrets-contract.yaml`,
`expected-inventory`, offline gates, Ruby tests. Verify with `helm lint`, `helm template` + schema
validation, policy check, seed-script unit tests, and a grep gate proving no secret literal entered
Git.

**v5 — Phase 3 additions:**

| # | Work | Verification |
|---|---|---|
| P3-1 | Portal chart patch: separate BPDM and SD Factory token-address values, defaulting to `centralidp.address` (G1-1, §4.1) | `helm template` test: BPDM/SD Factory token addresses = shared CentralIDP while JWT authority, `Keycloak:central` and frontend authority = ours; render with the patch but no new values = byte-identical to the current render |
| P3-2 | BDRS repoint: `BPNDIDRESOLVER__*`, the four directory references per ADR, removal of the BDRS rule from the `release26-09` egress policy (§4.3) | grep gate: no `release26-09` reference left except the documented exceptions |
| P3-3 | Chart forks: sha256 pins for every vendored `.tgz`; recovery values explicitly empty in our values; offline gate failing on non-empty recovery values or a copied Job spec (G1-2) | Ruby test under `tests/` with negative cases |
| P3-4 | **BDRS chart comparison:** obtain the published `bdrs-server` 0.6.0 package (the one outbound read in this phase, approved separately), record both digests, `diff -r` the extracted trees, and classify every difference as benign / BE-293 change / unexplained. Repeat for the `9e4524fb…` centralidp copy against published 4.2.1 to close caveat 2. Output: an appendix to the report. Any **unexplained** difference stops Phase 3. | diff recorded with digests; no unexplained difference |
| P3-5 | Seed content: our CX-Central seed per the ADR (incl. `arena` if option (a)); `sslRequired: external`; no `satest*` unless the ADR keeps them | render test on the seed Job env; JSON lint |
| P3-6 | Admin-key provisioning per §4.9: Secret contract entries, `envValueFrom` wiring, seed-job Role without `pods/log`, rotation step | render test; Role check; seed-script unit test with a fake API |

**STOP — Gate 3.**

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
documented BPDM exception** (and SD Factory, which stays skipped). Before the D4 action, record the
`idp_name` orphan inventory from Phase 1b. **STOP — Gate 6.**

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
| **A12** | **Isolation** | **Zero writes into `release26-09`.** Evidence from configuration and NetworkPolicy, not assumption. Only documented traffic: BPDM on the public testbed, with its machine token from the shared CentralIDP (G1-1). Where NetworkPolicy cannot tell the two Keycloaks apart (shared ingress IP, §4.8), use rendered configuration plus Keycloak access logs. |
| A13 | IAM exposure | Keycloak admin API and console not reachable externally; realm endpoints are |
| A14 | No default secrets | No seeded placeholder or default admin credential accepted |
| **A15** | **Failed-onboarding leak** | Two deliberate failures. **(a)** An invitation failure before step 9: expect Keycloak objects with only a `company_invitations.idp_name` trace. **(b)** A failure after submission: expect cleanup only through operator decline. Record exactly what remains, then clean up with the Phase 11 runbook (§4.4). |
| A16 | Offer client scope | Only if offer setup is exercised: an offer client created by the Portal carries the `bpn` claim in its token (§4.5, the ADR option) |

### Phase 11 — operations, handover, decommission

Backup/restore drill across Vault, both Keycloak databases, the Portal schema, issuer, IdentityHub and
BDRS from one recovery point. Runbooks: Vault unseal, Keycloak realm backup/restore, key and secret
rotation, credential revocation, node-event recovery. Update the Alpha handover. Hand Saud the §4.4
list for removal — **we do not touch it**. v5: add a **failed-invitation cleanup runbook** for our own
IDPs. It is keyed on `company_invitations.idp_name` and the Keycloak alias list, not on
`iam_identity_providers` (§4.4).

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
lead time Saud's DNS records take. v5 estimate: the Phase 3 additions P3-1 to P3-6 add roughly 1–1.5 days.
Phase 1b is under half a day once access is restored. The deferred BPDM phase is a further 2–3 days if taken.

---

## 9. Claude Code kickoff

### v5 — Phase 2 (ADR)

```text
Read docs/dev/BE-293-alpha-portal-test-replica-roadmap-v5.md completely, then
docs/dev/BE-293-phase1-discovery-report.md.
Follow section 3 (rules) strictly. release26-09 is READ-ONLY.
Gate 0 is NOT PASSED. Gate 1 is PASSED (section 0). Do not reopen D1, BDRS or G1-1..G1-4.

Write docs/dev/BE-293-alpha-iam-and-identity-adr.md as specified in section 6 Phase 2,
including the v5 list. For each open choice, give a recommendation with reasons and leave
the decision to Payam. Items marked "to verify" in section 4.9 must be verified from
source with file:line, or marked UNVERIFIED.

Documents only. No chart, values, code, branch, cluster or Git changes. Do not print
secrets. Then stop for Gate 2.
```

Phase 1b (§4.10) uses the v4 Phase 1 kickoff below, limited to §4.10, after Alpha access is restored.

### v4 — Phase 1 (retained)

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

## Appendix A — Portal IDP configuration surface (filled in Phase 1; full evidence in report item 3)

Paths: values = `alpha/portal-release-prepared/values-be293-portal.yaml`; chart = `portal-2.6.0.tgz!templates/…`.

| Area | What | Current | Target | Evidence |
|---|---|---|---|---|
| Portal values | CentralIDP address | `https://centralidp.test.tractus-x.com` | `https://centralidp-be293.test.tractus-x.com` | values `:19-20` |
| Portal values | SharedIDP address | `https://sharedidp.test.tractus-x.com` | `https://sharedidp-be293.test.tractus-x.com` | values `:21` |
| Frontend | authority, realm, client id | derived from `centralidp.address` + `/auth`; `CX-Central`; `Cl2-CX-Portal` / `Cl1-CX-Registration` | follows; same IDs with stock seed | chart `deployment-frontend-portal.yaml:65-91`, `deployment-frontend-registration.yaml:61-65` |
| Frontend | redirect URIs / web origins | set in the **centralidp seed** (`realmSeeding.clients.*`), web origins `+` | Portal-be293 hosts | report item 1 |
| Backend (5 services) | JWT metadata / valid issuer | derived from `centralidp.address` | follows; must equal real token `iss` (A9) | chart `deployment-backend-administration.yaml:369-376` |
| Backend (5 services) | valid audience | `Cl2-CX-Portal`, `Cl1-CX-Registration` | unchanged | chart `values.yaml:321-324` |
| Backend | `Keycloak:central` | `centralidp.address`, `CX-Central`, `sa-cl1-reg-2`, `be293-portal-keycloak/central-client-secret` | ours, new secret | values `:92-97`; `secrets-contract.yaml:30` |
| Backend | `Keycloak:shared` | `sharedidpAddress`, `sa-cl1-reg-1` (master), `…/shared-client-secret` | ours, new secret | values `:98-100`; `secrets-contract.yaml:31` |
| Registration / Administration | IdP alias | generated (`be293-alpha-idp-N`) | unchanged | `InvitationProcessService.cs:79` |
| Processes worker | IDP settings | as above + `PROVISIONING__CENTRALREALM` | follows | chart `cronjob-backend-processes.yaml` |
| **Outbound: BPDM** | token endpoint, client | **derived from `centralidp.address`**; `sa-cl7-cx-5` | **shared, unchanged (D1a) — via chart patch P3-1** | chart `cronjob-backend-processes.yaml:146-147`, `deployment-backend-administration.yaml:120-121`; values `:196-198` |
| **Outbound: SD Factory** | token endpoint, client | derived from `centralidp.address`; `sa-cl8-cx-1` | **shared, unchanged (G1-1) — via P3-1**; step skipped | chart `cronjob-backend-processes.yaml:242-243`; values `:199-201` |
| Outbound: Clearing House / DIM / Custodian | token endpoint | disabled hosts (`*.disabled.invalid`) | unchanged | values `:52-62` |
| **BDRS** | management address, API key, 4 directory references | `release26-09` / shared public directory | `be293` per ADR | values `:44-48`; §4.3 |
| IdentityHub / IssuerService | `APPLICATIONCHECKLIST__IDENTITYHUB__*`, administration `issuerdid` | `release26-09`, shared issuer DID | `be293` | values `:127`, `:205-228` |
| Kubernetes Secrets | IdP client-secret keys | `be293-portal-keycloak`: `central-client-secret`, `shared-client-secret`; `be293-portal-interfaces`: `bpdm-client-secret`, `sdfactory-client-secret` | central/shared new; bpdm/sdfactory unchanged | `secrets-contract.yaml:27-36` |
| NetworkPolicy | egress to Keycloak / `release26-09` | `be293-portal-release26-09-egress` (incl. BDRS 8081); Keycloak via `ipBlock 188.34.116.149/32:443` | BDRS rule removed; Keycloak limit per §4.8 | `networkpolicies-be293-portal.alpha-release.yaml:98-145,167-180` |
