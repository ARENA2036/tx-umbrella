# BE-293 Alpha — Own IAM and Identity Stack in `be293`: Roadmap v2

**Date:** 2026-11-13
**Supersedes:** `BE-293_Alpha_Own_Identity_Stack_Roadmap.md` (2026-11-12)
**Owner:** Payam (BE-293), decision: David Görzig, coordination: Saud Khan
**Status:** Plan. Nothing in this roadmap is approved for execution until Gate 0 is passed.

---

## 0. What changed in v2, and why

v1 planned an own **identity stack** (Vault, IssuerService, IdentityHub) in `be293` and explicitly said:
*"Borrow from `release26-09`: Central IDP / Shared IDP (Keycloak) for login and service accounts."*

The platform side has now asked:

> *"Could you please use a separate centralidp and sharedidp for your portal testing, instead of using the central one?"*

That request removes the last borrowed dependency for Portal login and provisioning. It is also, on its own
merits, the right call: our Portal does not only *read* from the shared Keycloak, it **writes** to it. Every
company onboarding creates an identity provider in the shared `CX-Central` realm and a realm in the shared
`sharedidp`, plus clients, roles and users. The `idp2` alias collision (A07) and the `0342`
`APPLICATION_ACTIVATION` 401 against `https://centralidp.test.tractus-x.com/auth/realms/CX-Central/protocol/openid-connect/token`
are both symptoms of several Portals sharing one realm namespace.

| | v1 | v2 |
|---|---|---|
| Scope | Vault + IssuerService + IdentityHub | **+ CentralIDP + SharedIDP + their PostgreSQL** |
| Helm releases in `be293` | `be293-portal`, `be293-identity` | `be293-portal`, **`be293-iam`**, `be293-identity` |
| Borrowed from `release26-09` | Keycloak, BPDM, resolver | **BPDM, resolver only** — Keycloak no longer borrowed |
| Effort to acceptance | ~5–6 days | **~8–11 days**, depending on D1 below |
| Order of work | identity stack → Worker → re-onboard | **IAM first**, then identity stack, then re-onboard **once** |

**Why IAM first:** re-onboarding the three companies creates realms, identity providers, clients and users.
Doing that against the shared Keycloak and then migrating means doing it twice and leaving residue in a
namespace we do not own. One onboarding, after both stacks are live, is cheaper and cleaner.

---

## 1. The one question that must be answered before Gate 0

**D1 — Will the shared central services still accept our tokens?**

Our Portal does not only authenticate humans against CentralIDP. It also obtains **service-account tokens**
there and presents them to services in `release26-09` — at minimum **BPDM Pool/Gate** (`/v6`), and depending
on configuration BPN Discovery, Discovery Finder, SD Factory and Clearing House.

A JWT from our own CentralIDP has a different `iss` and a different JWKS URI. A Spring resource server
configured with a single `issuer-uri` **will reject it with 401**. This is not a theoretical risk — it is the
same failure class as the `0342` 401 already recorded.

Three possible answers, with very different costs:

| | Answer | Consequence | Added effort |
|---|---|---|---|
| **D1-a** | Portal keeps using **shared CentralIDP service accounts for outbound calls only** (BPDM etc.), while human login, realm/IdP provisioning and company users move to our own IDPs | Smallest change. Requires that the Portal backend supports a per-integration token endpoint distinct from the login authority — **`[VERIFY]` in Phase 1B**, and requires the platform side to accept that we still hold `sa-cl7-*` style service accounts in their realm | +0 d |
| **D1-b** | Shared services are extended to trust our issuer as a **second** issuer | Change inside `release26-09` → Saud/platform owners, not us | +0 d for us, unknown for them |
| **D1-c** | Neither → we also need **own BPDM (+ PostgreSQL, + its own realm clients)** in `be293` | Largest. Also forces a decision on BPN Discovery / Discovery Finder | **+3–4 d** |

**Ask the platform side explicitly which of D1-a / D1-b / D1-c applies.** Do not start Phase 3 before this is
answered: it changes the chart scope, the realm seed content and the acceptance tests.

Two further questions to the same people:

- **D2 — Hostnames.** `centralidp-be293.test.tractus-x.com` and `sharedidp-be293.test.tractus-x.com` under the
  existing `*-be293.test.tractus-x.com` pattern — confirmed available and covered by DNS/cert issuance?
- **D3 — Residue in the shared Keycloak.** Our Portal has already created identity providers in shared
  `CX-Central` and realms in shared `sharedidp` for `BPNL000000000342`, `BPNL00000000043D`,
  `BPNL00000000052O` (and possibly the `idp2`-colliding alias). After the switch these are orphaned. We will
  **not** touch them. Ask who removes them and when, and record the answer.

---

## 2. Goal (v2)

Run a complete, persistent, self-contained **IAM and identity stack** in the Alpha namespace `be293`, so that
BE-293 Portal performs login, partner invitation, company onboarding and credential issuance end to end,
without writing into any namespace we do not own, and survives pod and node restarts.

**Definition of done**

1. A human logs into the BE-293 Portal through **our** SharedIDP realm, brokered by **our** CentralIDP. No
   request from the Portal browser flow or backend reaches `centralidp.test.tractus-x.com` or
   `sharedidp.test.tractus-x.com` — except, if D1-a is chosen, the explicitly documented outbound
   service-account token calls.
2. Partner invitation creates a realm and an identity provider **in our SharedIDP/CentralIDP**, with a unique
   alias (A07 regression), and the invitation mail arrives.
3. An approved Portal company completes `IDENTITY_WALLET`, `BPNL_CREDENTIAL` and `MEMBERSHIP_CREDENTIAL` with
   real, verifiable credentials; `APPLICATION_ACTIVATION` reaches `DONE`.
4. An unapproved holder receives no credential.
5. Deleting every pod of both stacks (Keycloak ×2, Vault, IssuerService, IdentityHub, all PostgreSQL) loses no
   keys, no realms and no users; login and issuance still work afterwards.
6. No secret appears in logs, Git, Helm values or chat. No change outside `be293`.
7. Tests, lint and security checks run after the last edit, with recorded results.

**Accepted limits (Gate 0):** credentials from this issuer are trusted only inside the BE-293 stack;
connectors in `connector` and services in `release26-09` do not trust it. Tokens from our CentralIDP are
likewise only trusted inside BE-293, subject to D1.

---

## 3. Rules for every phase (non-negotiable — unchanged from v1, plus IAM additions)

| Rule | Detail |
|---|---|
| Namespaces | **Change only `be293`.** `release26-09`: read-only (get, logs, read-only psql). Every other namespace: do not touch, not even read, without asking. |
| Cluster | Always `--kubeconfig ~/.kube/alpha.yaml --context alpha`. Never the default context. DEV (`stackit-dev.yaml`) is reference only, read-only. |
| Gates | Stop at every gate and report. No live change without explicit approval for that specific step. |
| Before any live change | Show target, server-side dry-run, diff, rollback, and a backup where data is involved. |
| Secrets | Never print, log, commit or paste secret values. Load into variables or Secrets only. Never put secrets on the command line. |
| Vault | No in-memory or dev-mode Vault. No root token in applications. |
| **Keycloak (new)** | **No `--optimized` image with dev settings. No `start-dev`. No H2/in-memory database. Admin REST API never reachable from outside the cluster. No default or seeded placeholder client secret survives into the running realm.** |
| Keys | No super-user keys in the Portal. Scoped keys only. |
| Git | Preserve uncommitted work. No push, no PR without approval. No AI attribution anywhere (commits, PRs, files). Use the existing Git identity. |
| Evidence | Distinguish observed, prepared, deployed and verified. Never claim a result that was not produced. |
| **Conventions (new)** | New charts/values follow the existing release-package conventions in `alpha/portal-release-prepared`: a `values-be293-*.yaml` per release, `images.lock.yaml`, `secrets-contract.yaml` (key names only), `expected-inventory*.txt`, offline gates in `tools/render-release.sh`, Ruby tests under `tests/`. |

---

## 4. Confirmed facts

### 4.1 Carried over from v1 (do not re-investigate)

- **Incident 2026-11-12:** all four Vaults in `release26-09` run `Storage Type: inmem`; a node event at ~01:50
  UTC rescheduled all pods and lost key material. IssuerService super-user key → 401; IdentityHub 01 → 500
  (`NullPointerException` in `ParticipantServicePrincipalResolver`). Saud confirmed no recovery procedure.
- **BPN credential root cause:** Portal registers holders with `holderId = BPN`; the shared issuer's
  `BpnCredential-id` uses a `database` attestation on `custom_attestation_claims` (DID-keyed rows only) → no
  row → `success(null)` → `putAll(null)` NPE → 500.
- **Proven DEV pattern:** `holders-database-attestation` (database, datasource `holder`, table `holders`) +
  `holder-properties-attestation` (type `holder`); `tx-bpncredential` mappings `did → credentialSubject.id`,
  `holder_id → credentialSubject.holderIdentifier`, `holder_id → credentialSubject.bpn`. DEV Membership has
  **no** `memberOf` and is not a valid template.
- **Known Worker defects:** deterministic `BuildHolderPid`; no holder update on 409; `BPNL000000000342` falsely
  `BPNL_CREDENTIAL = DONE`.

### 4.2 New in v2 — current IAM wiring (observed)

| Item | Value | Source |
|---|---|---|
| CentralIDP used today | `https://centralidp.test.tractus-x.com/auth/realms/CX-Central` | `0342` activation 401, 2026-11-09 07:48 |
| SharedIDP used today | shared instance in `release26-09` (`sharedidp-postgresql-0` present) | Alpha topology inventory |
| Shared Keycloak databases | `centralidp-postgresql-0`, `sharedidp-postgresql-0` in `release26-09` | Alpha topology inventory |
| Known IAM defects on the shared instance | A07 `idp2` identity-provider alias collision on invitation; `0342` `APPLICATION_ACTIVATION` 401 at the CentralIDP token endpoint | Open items 5 and 9 |
| Shared-realm SMTP | live Office 365 configuration, deliberately kept on 2026-11-08 (gate S9); the smtp4dev overlay does not override it | Session report 2026-11 |
| Seeding history | CentralIDP and SharedIDP realm-seeding jobs have an OOMKilled history; memory was raised | Master handover §22 |

### 4.3 Explicitly **not** yet verified (Phase 1B must produce evidence)

Everything below is an assumption to be checked against the actual chart and source, not a fact:

- `[VERIFY]` Which `centralidp` / `sharedidp` subcharts and versions ship inside
  `handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/`, and whether they can be installed standalone as a
  separate release.
- `[VERIFY]` Realm names (`CX-Central`, and the SharedIDP template/master realm), the exact client IDs and
  technical service accounts the Portal 2.6.0 chart expects, and which of them the realm seed creates.
- `[VERIFY]` Every Portal values key and backend environment variable that carries an IDP address, realm,
  client ID, client secret, metadata address, valid issuer or valid audience — frontend, backend services,
  registration, administration, and the processes worker.
- `[VERIFY]` **Decisive for D1-a:** whether the Portal backend resolves the token endpoint for outbound
  integrations (BPDM, SD Factory, Clearing House) from a per-integration setting that is independent of the
  login authority, or derives all of them from one central address.
- `[VERIFY]` Which Portal DB tables bind to Keycloak identifiers (`iam_identity_providers`, `iam_users`,
  `iam_clients`, `iam_service_accounts` and equivalents), and whether the operator company and its admin user
  keep stable identifiers when a fresh realm is seeded from the same seed version.
- `[VERIFY]` DNS for `centralidp-be293` and `sharedidp-be293`, and that the Keycloak and portal-iam images are
  pullable in this cluster.

---

## 5. Roadmap

### Gate 0 — Decision (Payam + David + platform side)

- [ ] David approves building an own **IAM and identity stack** in `be293`, accepting the trust limits in §2.
- [ ] **D1 answered** (a / b / c) — determines chart scope and effort.
- [ ] **D2** hostnames agreed: `centralidp-be293`, `sharedidp-be293`, `issuer-be293`, `identityhub-be293`, all
      under `.test.tractus-x.com`.
- [ ] **D3** owner and timing for removing our residue in the shared Keycloak recorded.
- [ ] **D4 — Portal state.** Decide between:
      **(i) clean re-seed** of the Portal database together with the new realms (one consistent world, no stale
      IAM rows, all three companies onboarded once), or
      **(ii) keep the Portal database** and clean up stale `iam_*` rows that point at the old realms.
      Recommendation: **(i)**, with a verified `pg_dump` taken and stored first. (ii) carries a long tail of
      half-migrated identities and is harder to prove correct.
- [ ] **D5 — SharedIDP SMTP.** Our own SharedIDP means we own the mail configuration. Recommendation: point it
      at the existing `smtp4dev` sink for test onboarding, so invitations to external addresses cannot leave
      the cluster. Office 365 only if real mail delivery is a stated acceptance requirement.
- [ ] **D6 — Membership semantics** (`memberOf` source, e.g. constant `Catena-X` for approved companies) —
      carried over from v1.

**Nothing live happens before this gate.**

---

### Phase 1 — Read-only discovery (≈ 1 day)

#### 1A — Identity stack (unchanged from v1)

1. Worker: map every use of `APPLICATIONCHECKLIST__IDENTITYHUB__*` and `BPNDIDRESOLVER__*`; which checklist
   step calls BDRS, with what, and is it required?
2. Worker: every path that sets `BPNL_CREDENTIAL = DONE`; explain the false `DONE` on `0342`; determine the
   commit the 2026-11-07 Worker image was built from.
3. Worker: caller of `RequestCredentialAsync` and which values are available (application ID, approval time).
4. DEV blueprint: inventory `identity-and-trust-bundle` and the seed job — components, images, ports,
   settings, secrets, participant ID encoding in URLs (0.17.0 admin API uses the **plain** ID).
5. Alpha read-only: DNS for the agreed hostnames, NetworkPolicies in `be293`, image pullability.
6. Confirm `tractusx/issuerservice:0.4.1` and `tractusx/identityhub:0.4.1` suffice (no custom image).

#### 1B — IAM (new)

7. **Chart inventory.** What `centralidp` and `sharedidp` subcharts exist in the pinned umbrella package;
   their chart versions, Keycloak image and tag, the realm-seeding image, and whether each can be deployed as
   its own release. Record exact paths and versions.
8. **Realm seed content.** What the CentralIDP seed creates: realm name, clients, technical service accounts,
   roles, the operator company admin user, and which values control redirect URIs, web origins and frontend
   URL. Same for the SharedIDP seed (template realm, SMTP block, password policy).
9. **Secret surface.** Every client secret and admin credential the seeds consume, and *how* they are
   supplied (plain values key, existing Secret, file). This decides the secret-handling design in Phase 2.
   Record key names only, never values.
10. **Portal configuration surface.** Produce the complete table of every setting in Portal chart 2.6.0 and
    the backend that references an IDP — see the checklist in Appendix A, filled with real keys and
    `file:line` evidence.
11. **D1 evidence.** Trace the outbound call path from the processes worker to BPDM: which token endpoint,
    which client, configured where. State plainly whether D1-a is technically possible without a code change.
12. **Portal DB binding.** Which tables and columns hold Keycloak realm aliases and user/client identifiers,
    and what breaks for each if the realm changes. Feeds D4.
13. **A07 and the `0342` 401.** With the shared realm read-only, determine whether both are purely a
    consequence of a shared realm namespace, or whether a Portal-side fix is still required on our own IDPs.

**Output:** one discovery report, each item as finding / evidence (`file:line`, command + relevant output) /
confirmed or inferred. **STOP — Gate 1.**

---

### Phase 2 — ADR (≈ 0.5–1 day)

Write `docs/dev/BE-293-alpha-iam-and-identity-adr.md` covering both stacks.

**IAM (`be293-iam`)**

- **Topology:** CentralIDP + SharedIDP, each with its own PostgreSQL and PVC on `premium-perf1-stackit`.
  Separate release from `be293-portal` and `be293-identity`: independent rollback, smaller blast radius.
- **Keycloak runtime:** production mode, external database, `KC_PROXY_HEADERS` / forwarded-header handling set
  so the issuer in tokens is the public **HTTPS** URL. `[VERIFY]` exact keys for the shipped Keycloak version.
  This is the same bug class as the issuer-service status-list `http` vs `https` warning — get it right once,
  explicitly, and assert it in a test.
- **Exposure:** public Ingress serves only the endpoints the browser flow needs (`/realms/*` and static
  assets). The **admin REST API and admin console are not published**; the Portal backend reaches them through
  the in-cluster Service. If an admin console is wanted for operators, it is a separate, restricted path with
  an explicit decision recorded.
- **Secrets:** admin credentials and all client secrets generated out of band, stored in Kubernetes Secrets,
  referenced by the release. Where a chart only accepts literal values, use a local, git-ignored values file
  with restrictive permissions and record **key names only** in `secrets-contract.yaml`. No default or
  placeholder secret may survive into the running realm — Phase 10 asserts this.
- **Seeding:** idempotent, fail-closed, memory sized against the known OOM history, never logs secrets, safe to
  re-run.
- **Identity provider aliases:** unique per company, with the A07 prefix fix applied from the start.
- **SMTP:** per D5.
- **NetworkPolicies:** default deny; explicit allows (Portal backend/worker → Keycloak admin + token; ingress
  → public realm endpoints; Keycloak → its PostgreSQL, DNS, SMTP sink).
- **Outbound trust:** document the D1 outcome precisely — for D1-a, name every integration that still points at
  the shared CentralIDP, and why that is acceptable.
- **Rollback:** previous Portal values and Secret, old release kept installable; Portal DB restore point.

**Identity (`be293-identity`)** — as v1: Vault with Raft on PVC, Kubernetes auth, least-privilege policies, no
root token in workloads, documented unseal-key handling and snapshots; PostgreSQL per service; issuer
participant and DID `did:web:issuer-be293.test.tractus-x.com`; holder DIDs under
`did:web:identityhub-be293.test.tractus-x.com:<BPN>`; DEV issuance pattern with an `expression` rule on holder
property `approvalSource = portal-be293`; scoped API keys only; public exposure limited to DID documents, DCP
endpoints and the status list; BDRS decision per Phase 1A.

**STOP — Gate 2.**

---

### Phase 3 — Charts and values, local only (≈ 2–2.5 days)

On a new local branch in `BE293_ALPHA/tx-umbrella`:

**3A — `be293-iam`:** values for CentralIDP and SharedIDP (image pins by digest in `images.lock.yaml`,
PostgreSQL with PVC, Ingress with `nginx` + `letsencrypt-prod`, probes, resources, non-root and read-only root
filesystem where supported), realm seed configuration, NetworkPolicies, `secrets-contract.yaml` entries,
`expected-inventory` and offline gates, Ruby tests mirroring the existing suite.

**3B — `be293-identity`:** as v1 — Vault/Raft, IssuerService, IdentityHub, PostgreSQL, Services, Ingress,
NetworkPolicies, idempotent seed job (participant + DID publish, attestations, credential definitions,
approval rule, scoped API keys into Kubernetes Secrets, 409 = verify not overwrite).

**3C — Portal rewiring (prepared, not applied):** a values overlay switching every entry from Appendix A to the
new hosts, plus the D1-a exceptions if applicable.

**Verification:** `helm lint`, `helm template` + schema validation, policy/security check, seed-script unit
tests, the existing release gates, `git diff --check`, and a grep gate proving no secret literal entered Git.

**STOP — Gate 3: diff and test results reviewed.**

---

### Phase 4 — Worker changes, local only (≈ 1 day) — unchanged from v1

`HolderProperties` gains `bpn`, `approvalSource` (default `portal-be293`), `applicationId`, `approvedAt`;
`PUT` holder on 409; new unique request ID per retry after a terminal failure; clear, secret-free failure
reasons for 401/500; fix the false `DONE`; unit tests; full suite and build with recorded results.

**STOP — Gate 4.** Image build/push via the retrigger-images workflow only after approval, digest recorded.

---

### Phase 5 — Deploy `be293-iam` (live, step by step, ≈ 1 day)

Each step: dry-run → diff → approval → apply → verify → record.

1. Secrets and NetworkPolicies.
2. PostgreSQL for both Keycloaks; **restart test** (delete pod, data survives).
3. CentralIDP and SharedIDP; health, readiness, Ingress and TLS.
4. Realm seeding; verify realm, clients, service accounts, roles — by name and count, never by printing
   secrets.
5. Verify the **issuer URL in an issued token is the public HTTPS URL**, and that
   `/.well-known/openid-configuration` is reachable publicly while the admin API is not.
6. **Full restart test:** delete every pod of the release; realms, users and clients survive, login still works.

**STOP — Gate 5.**

---

### Phase 6 — Switch the Portal to our own IAM (live)

1. `pg_dump` of the Portal database, stored and verified restorable (precondition for D4 either way).
2. Back up current Portal values and Secret **metadata** (not values).
3. Apply the Phase 3C overlay: frontend, backend, registration, administration, processes worker.
4. Per D4(i): re-seed Portal IAM data consistently with the new realms. Per D4(ii): clean the stale `iam_*`
   rows, with the exact statements reviewed and a backup in hand.
5. Verify: operator admin login through the browser; token `iss` and `aud` correct; backend accepts it; no
   request leaves to the shared Keycloak except the documented D1-a exceptions (verify by log/NetworkPolicy
   evidence, not by assumption).

Rollback: previous values + Secret + Portal DB restore.

**STOP — Gate 6.**

---

### Phase 7 — Deploy `be293-identity` (live, step by step, ≈ 1 day)

As v1 Phase 5: Secrets and NetworkPolicies → Vault (install, init, unseal, auth, policies; **restart test**)
→ PostgreSQL (restart test) → IssuerService and IdentityHub → seed job → Ingress/TLS, DID documents public
over HTTPS, status list reachable, admin APIs not public → **full restart test**.

**STOP — Gate 7.**

---

### Phase 8 — Switch the Portal Worker to the new identity stack (live)

Update `be293-portal-identityhub` with the new **scoped** keys; update the `APPLICATIONCHECKLIST__IDENTITYHUB__*`
settings; deploy the Phase 4 image by digest; verify with read-only calls (holder GET, DID state).
Rollback: previous Secret, values and image digest.

**STOP — Gate 8.**

---

### Phase 9 — Onboard the three companies once, end to end

`BPNL000000000342`, `BPNL00000000043D`, `BPNL00000000052O`, through the supported Portal flows only; no manual
Portal DB edits without separate approval and a backup. Invitation → realm and IdP created in **our** SharedIDP
and CentralIDP with unique aliases → company admin logs in → wallet, DID, BPN and Membership credentials →
`APPLICATION_ACTIVATION` `DONE`.

**STOP — Gate 9.**

---

### Phase 10 — Acceptance tests (record evidence)

| # | Test | Expected |
|---|---|---|
| A1 | Approved company onboarding | All credential steps `DONE`, credentials in wallet |
| A2 | Credential content | `credentialSubject.id` = holder DID, `bpn` = BPN, issuer = new issuer DID, valid signature, status list resolvable |
| A3 | Unapproved holder | No credential, clear failure, no 500 |
| A4 | Restart resilience | Delete every pod of both stacks; repeat A1 and A9 |
| A5 | Retry after failure | Failed request retried with a new ID, succeeds |
| A6 | Exposure (identity) | Admin/identity APIs unreachable externally; DID and status list reachable |
| A7 | Secret hygiene | No secrets in logs, Git, values or Helm release manifests |
| A8 | Final checks | Tests, lint, security scan after the last edit, with SHAs and timestamps |
| **A9** | **Portal login** | Operator admin and company admin log in through our SharedIDP; token `iss` is the public HTTPS URL of our CentralIDP; audience correct |
| **A10** | **Invitation (A07 regression)** | New partner invitation creates a uniquely aliased IdP, no collision, mail received at the configured sink |
| **A11** | **Activation** | `APPLICATION_ACTIVATION` reaches `DONE` — the `0342` 401 does not recur |
| **A12** | **Isolation** | No traffic from `be293` to shared Keycloak hosts except the documented D1-a exceptions; evidence from logs and NetworkPolicy |
| **A13** | **IAM exposure** | Keycloak admin API and console not reachable from outside; realm endpoints are |
| **A14** | **No default secrets** | No seeded placeholder client secret or default admin credential is accepted by the running realms |

---

### Phase 11 — Operations, handover, decommission

- Backup/restore drill: Vault snapshot + all PostgreSQL dumps (Portal, both Keycloaks, issuer, IdentityHub)
  from the same recovery point, restored into a scratch target. Approval required.
- Runbooks: Vault unseal and recovery, Keycloak realm backup/restore, client-secret and key rotation,
  credential revocation, adding a company manually, and what to do when a node event reschedules everything.
- Update the Alpha handover and open-items documents; record all image digests and Helm revisions.
- **Decommission request (D3):** hand the platform side the list of identity providers, realms, clients and
  service accounts our Portal created in `release26-09`, and ask them to remove what they want removed. We do
  not touch it.
- Carry-over open items: trust with Alpha connectors, BDRS long term, upstream null-handling bugs
  (EDC IdentityHub PR #1236; IdentityHub API-key NPE), and a possible later migration back to shared
  components if the organisation decides so.

---

## 6. Effort and risks

**Effort to Gate 10:** ~8–9 working days for D1-a or D1-b, ~11–13 for D1-c, plus review time at each gate.
The IAM work adds roughly 2.5–3 days of build and 1 day of live work on top of v1.

| Risk | Mitigation |
|---|---|
| **Shared services reject our tokens (D1)** | Answer D1 *before* Phase 3. Phase 1B item 11 produces the technical evidence. A13/A12 prove the outcome. |
| **Keycloak issuer URL wrong behind the proxy** | Explicit forwarded-header configuration in the ADR; A9 asserts the issuer in a real token, not the configuration |
| **Portal DB holds identifiers from the old realms** | D4 decision with a verified `pg_dump` first; Phase 1B item 12 enumerates exactly what binds |
| **Realm seed carries default/placeholder secrets** | Generated secrets only, `secrets-contract.yaml`, A14 |
| **Admin API exposed to the internet** | Ingress publishes realm endpoints only; A13 |
| **Seeding OOM (known history)** | Memory sized deliberately; seeding is idempotent and re-runnable |
| **Invitation mail leaves the cluster to real addresses** | D5: smtp4dev sink for test onboarding |
| Vault misconfiguration loses keys again | Raft + PVC, restart tests in Phases 5, 7 and A4, snapshot backups |
| Unseal-key handling | Explicit ADR decision; restricted Secret or KMS; documented recovery |
| Two trust worlds in Alpha | Accepted at Gate 0; documented; no connector changes |
| Hostname or DNS unavailable | Checked in Phase 1 before any build |
| Worker regressions | Unit tests, staged rollout, digest pinning, rollback values |
| Secret leakage via logs | Seeds never log secrets; IssuerService logs a super-user key on first creation — configure it via Secret and never share startup logs |

---

## 7. Claude Code kickoff prompt (v2)

Start Claude Code in `~/Projects/ARENA2036/BE293_ALPHA/tx-umbrella`:

```text
Read BE-293_Alpha_Own_IAM_and_Identity_Stack_Roadmap_v2.md completely. Follow section 3 (rules) strictly.

Gate 0 is [PASSED / NOT PASSED — set by me]. D1 is [a / b / c / UNANSWERED].
If Gate 0 is not passed, do Phase 1 only and stop.

Do Phase 1 (read-only discovery, 1A and 1B) now. You may read:
- ~/Projects/ARENA2036/BE293_ALPHA/tx-umbrella
  (including handoff/BE-293-umbrella-3.17.0 and alpha/portal-release-prepared)
- ~/Projects/ARENA2036/portal-backend-await-fix
- ~/Projects/ARENA2036/BE293_ALPHA/tx-umbrella-retrigger-images
- ~/Backup/Projects/public-tractus-x-umbrella (DEV blueprint, reference only)
- Alpha cluster namespaces be293 and release26-09, read-only, always with
  --kubeconfig ~/.kube/alpha.yaml --context alpha.

Do not modify any file, branch, cluster resource or Git state in Phase 1. Do not print secrets.
Appendix A must be returned filled in, with file:line evidence for every row.
Phase 1B item 11 (the D1 question) is the highest-priority item: answer it with evidence,
and say explicitly whether D1-a is possible without a code change.

Report each item as: finding, evidence (file:line, command + relevant output), confirmed or inferred.
Then stop and wait for my review (Gate 1).
```

---

## Appendix A — Portal IDP configuration surface (to be filled in Phase 1B)

Every row needs the real key, its current value's host, its target value, and `file:line` evidence. Rows are a
starting checklist, not a claim that each exists under this name.

| Area | What to find | Current | Target | Evidence |
|---|---|---|---|---|
| Umbrella/Portal values | CentralIDP address | `centralidp.test.tractus-x.com` | `centralidp-be293.test.tractus-x.com` | |
| Umbrella/Portal values | SharedIDP address | shared | `sharedidp-be293.test.tractus-x.com` | |
| Frontend | SSO/authority URL, realm, client ID | | | |
| Frontend | allowed redirect URIs / web origins in the seeded client | | | |
| Backend (all services) | JWT authority / metadata address | | | |
| Backend (all services) | valid issuer, valid audience | | | |
| Backend | CentralIDP admin connection: address, realm, client, secret | | | |
| Backend | SharedIDP admin connection: address, realm, client, secret | | | |
| Registration service | IDP settings | | | |
| Administration service | IDP settings, IdP alias prefix (A07) | | | |
| Processes worker | IDP settings | | | |
| **Outbound: BPDM** | token endpoint, client, secret | shared CentralIDP | **per D1** | |
| Outbound: BPN Discovery / Discovery Finder | token endpoint, client, secret | | per D1 | |
| Outbound: SD Factory / Clearing House | token endpoint, client, secret | | per D1 | |
| Kubernetes Secrets | every Secret key holding an IDP client secret | | | |
| NetworkPolicy | egress rules referencing Keycloak hosts | | | |
