# Missing Inputs, Blockers and Security Observations

**Status: BLOCKED** for installation; ready for engineering review. Each item names the input or decision needed and who provides it. The owners are roles, not people.

Labels:

| Label | Meaning |
|---|---|
| BLOCKED | Cannot be produced safely from the available evidence |
| MISSING INPUT | External value or decision required |
| DECISION | Owner choice with a documented default |

## Severity order (highest first)

| # | Blocker | Severity | Blocks |
|---|---|---|---|
| 1 | B-02 Private images in a personal-account registry; 10 of 14 cannot be rebuilt | Critical | Any install outside DEV |
| 2 | B-03 Vault bootstrap not packaged; live policy text unknown | Critical | Any install |
| 3 | B-11 Install on an empty cluster not proven (hooks, concurrent realm seeding, `did:web` TLS) | High | Install confidence |
| 4 | B-06 125 credential values and 13 Secrets to provision, with matching OAuth pairs | High | Install |
| 5 | B-01 Target platform state unknown | High | Install |
| 6 | B-04 Realm-seeding and IdentityHub-seed semantics on fresh install and upgrade | High | Safe install and upgrade |
| 7 | B-05 New domain means new DIDs and credentials | Medium (decision) | Identity continuity |
| 8 | B-08 BDRS token without `renew-self` | Medium | Runtime after 24 h |
| 9 | B-09 Live-only Keycloak and Portal state not reproduced | Medium | Functional parity |
| 10 | B-07 Sources not in pushed commits | Medium | Rebuilds only |
| 11 | B-10 Excluded provisioner and tenant connectors | Low (decision) | Scope |

## Blockers

### B-01: Target cluster state. MISSING INPUT. Owner: Platform Team

The target cluster was not inspected. Every target-state column is UNKNOWN. These need confirming:

- Kubernetes version
- namespace `be293`
- a default StorageClass (and whether `premium-perf1-stackit` exists)
- ingress-nginx class `nginx` with regex support
- cert-manager plus a ClusterIssuer (the package names `letsencrypt-dev`)
- ExternalDNS
- the DNS zone and suffix
- resource quotas

Also confirm the hostname pattern `<svc>.be293.dev.<suffix>` is acceptable; changing it means editing about 160 overlay entries and changes every DID.

### B-02: Container images: mirroring and provenance. MISSING INPUT. Owner: Platform Team and Development Team

All 14 private BE-293 images are digest-pinned in a private Docker Hub repository under a personal account. They must be copied **by digest** into an approved organization registry, which needs pull credentials from the current owner. See `inventory/IMAGE-INVENTORY.yaml`.

- **No source lock:** `portal-registration-claimfix-r1`, `portal-marketplace-claimfix-r1`, `portal-notification-claimfix-r1`, and the two Keycloak realm-seeding images. They can be mirrored, but not rebuilt.
- **No SBOM, provenance attestation or vulnerability report** for any private image, although the source checkout's publication contract requires them.
- **`python:3.11`** (post-install test-data Job) has no resolved digest, because no running pod exists.

**Who can pull and who can rebuild each image.** Registry access could not be tested from the packaging environment (outbound access to Docker Hub and quay.io is blocked). The table below therefore rests on DEV evidence: every image is running there, or ran there.

| Image group | Another engineer can pull? | Another engineer can rebuild? |
|---|---|---|
| 14 private `be293-images` (EDC ×2, IdentityHub, IssuerService, Portal ×6, DTR, Submodel, realm seeding ×2) | **No**: private repository, personal account; access must be granted or the images mirrored | EDC (`72755ae`, pushed to Federity-X `main`), IdentityHub (`3633af6`, pushed), DTR (`9ac65a3`, pushed): **yes**. IssuerService and processes worker (base commit pushed, patch untracked): **no**. Portal administration and migrations (`933aeeb25` local-only): **no**. Claimfix ×3, realm seeding ×2, Submodel (snapshot inventory untracked): **no** |
| Upstream `tractusx/*`, `postgres`, `hashicorp/vault`, `python`, `busybox`, `rnwood/smtp4dev`, `alpine/*` | Yes (public; not re-tested) | n/a |
| `bitnamilegacy/*` (Keycloak 25.0.6, PostgreSQL 15) | Yes today. It is the frozen Bitnami legacy repository with no updates, and continued availability is not guaranteed. Mirror by digest. | n/a |
| `alpine/curl:latest`, `busybox:1.28`, `busybox:1.36`, `python:3.11` | Yes, but the tags float. Mirror the resolved digests from IMAGE-INVENTORY; `python:3.11` has none. | n/a |

### B-03: Vault bootstrap automation. BLOCKED. Owner: Platform Team and Security Team

The DEV tooling was **not copied**:

- `hack/be293-dev-vault-bootstrap.sh`
- `hack/be293-dev-runtime-bootstrap.py`
- `hack/be293_vault_recover.py`
- `hack/be293_full_seed.py`, `be293-statuslist-recovery.zsh`, `be293-dcp-routing.zsh`

Reasons it cannot be packaged safely as-is:

- It hard-codes the DEV context `k8s-dev-01`, a local kubeconfig path, the DEV domain and a personal absolute path.
- It stores the Vault root token and unseal key in a namespace Secret (S-04).
- It depends on the untracked DEV values stack, which still contains plaintext credentials.
- It contains a credential-derived Vault alias.
- It is untracked and unreviewed.

The required end state is documented in `docs/VAULT-CONTRACT.md`, derived from that tooling. **The exact live policy text is UNKNOWN.** An export of the 6 policies and the role (`vault policy read …`, `vault read auth/token/roles/be293-runtime`) is needed to confirm it, including who may write the shared alias `super-user-apikey`.

### B-04: Seeding behaviour on an empty cluster. DECISION. Owner: Identity Owner and Integration Team

- **Realm seeding.** `centralidp`/`sharedidp.realmSeeding.recoveryExistingRevisions` lists revisions 7 and 13. On a fresh cluster (where `lookup` finds no Job) **both generations are created and run concurrently**, each with its own pinned seeding image. Both revision 7 Jobs **failed** on DEV.
  - Kept unchanged here, to reproduce revision 21.
  - Candidate change, which needs an owner decision and a test: keep only revision 13 for a fresh install.
- **IdentityHub seed hook.** It runs post-install *and* post-upgrade. IdentityHub upserts credential requests by `holderPid`, so a re-run overwrites earlier requests (DEV follow-up 2). Any `helm upgrade` without `--no-hooks` re-runs it.
- **First-start dependencies.** The seed and BDRS setup hooks need Vault (B-03) and every runtime Secret. On DEV the 2026-10-16 seed hook failed and was recovered manually.

### B-05: Identities on a new domain. DECISION. Owner: Identity Owner

- **Fixed values.** BPNs and participant context IDs are fixed (`COMPONENT-MATRIX.md`).
- **DIDs.** They are `did:web` and contain the DNS name. On another domain the target gets **new DIDs, keys and credentials**, issued fresh by the seed hook.
- **Reusing DEV identities.** That requires the same domain *and* a consistent restore of Vault plus the IdentityHub, IssuerService and BDRS databases. It is not covered by this package.

### B-06: Credential values. MISSING INPUT. Owner: Security Team

- **To provide:** 125 values in the secrets overlay, plus 13 pre-provisioned Secrets, and `identityhub-superuser` when the optional overlay is used (`docs/SECRETS.md`).
- **Matching pairs:** OAuth client secrets must match between Keycloak seeding and their consumers. `TX_PORTAL_CALLBACK_CLIENT_SECRET` must equal the Central IDP secret of `sa-cl24-01`.
- **Key material:** the connector key material (`token-signer-*`, `token-encryption-aes-key`) must be generated per environment.
- **Never copy from DEV.**

### B-07: Source not reproducible from Git. BLOCKED (rebuild only; mirroring still works). Owner: Development Team

These are not in any pushed commit:

- Portal commit `933aeeb25` (local only) and its connector-provisioning patch
- the 26 chart and image patches (25 untracked in the source checkout)
- the DEV values stack (13 of 18 files untracked)
- the publication manifest and lock files

The packaged chart is still exact, because it vendors the already-patched dependency packages. Rebuilding those packages from upstream with the source checkout's `hack/helm-dependencies.bash` was **not verified**.

### B-08: BDRS Vault token lifecycle. MISSING INPUT. Owner: Platform Team

On DEV the BDRS runtime token was never given `lookup-self`/`renew-self`. This is documented in the 2026-10-22 acceptance record. The target policy must include both (`docs/VAULT-CONTRACT.md` §4); otherwise BDRS loses Vault access after 24 hours.

### B-09: DEV state that Helm does not hold. MISSING INPUT. Owner: Identity Owner and Portal Owner

Not reproduced by this package:

- **Keycloak realm changes applied live by scripts.** The source checkout contains `hack/be293-keycloak-*` cutover, redirect, federation and JWKS scripts. The HTTPS-cutover and Shared IDP preparation overlays are **not** part of the revision 21 values stack.
- **Portal database content:** onboarded companies, users, applications.
- **IdentityHub and IssuerService state for onboarded participants.**
- **BDRS entries added after seeding.**

Whether the target needs any of this is UNKNOWN. A fresh install gives only the seeded baseline.

### B-10: Components excluded from this baseline. DECISION. Owner: Integration Team

Excluded:

- `connector-provisioner` (namespace `be293-connectors`, source never committed)
- the tenant connectors `be293-onb0003-edc` and `edc-bpnl00000000015g`
- the DNS-test Ingress

They are separate releases and were not needed for the revision 21 release. Including them needs committed source, a security review of the provisioner RBAC, and Vault tenant policies.

### B-11: Install on an empty cluster not proven. MISSING EVIDENCE. Owner: Integration Team and Platform Team

The offline checks prove render equivalence only. Not yet observed:

- whether every hook completes on a cold start (the Portal migration hooks have no database wait; Helm's default per-hook timeout is 5 minutes);
- whether the concurrent revision 7 and revision 13 realm-seeding Jobs succeed on an empty Keycloak;
- whether the seed hook (`backoffLimit: 2`) reaches 16 `ISSUED` credentials;
- whether `did:web` resolves with the target DNS and TLS.

Run `docs/ISOLATED-CLUSTER-TEST-PLAN.md` on a disposable cluster before any shared target.

## Security observations (no action taken; recorded for owners)

| ID | Observation | Evidence |
|---|---|---|
| S-01 | With the plain revision 21 configuration, the IdentityHub and IssuerService super-user keys, the Portal IdentityHub and IssuerAdmin keys, the BPN-DID-resolver key and the IdentityHub STS client secret are **Helm values**. They are stored in every Helm release Secret. The EDC management key and DB passwords are plain env values. Mitigation in this package: `values-be293-identityhub-superuser-secretref.yaml` (optional). The EDC SecretRef work is out of scope (no EDC GA upgrade). | revision 21 render; `docs/SECRETS.md` §C |
| S-02 | `identity-and-trust-bundle.identity-hub-postgres.identityhub.endpoints.accounts.authKeyAlias` is a well-known upstream **default credential string** used as a Vault alias *name*. It was kept unchanged because renaming it changes behaviour (the Vault path). Make sure the value stored under that alias is not the upstream default. | overlay line `authKeyAlias` |
| S-03 | The EDC data plane proxy API key is the vendored chart's **embedded upstream default**. An override path is documented in `docs/SECRETS.md` §C; not applied. | render, 2026-11-02 |
| S-04 | On DEV, the Vault root token and unseal key are stored together in Secret `be293-vault-init`. Do not reproduce this. | live Secret key names |
| S-05 | Vault (`http://be293-vault:8200`) and several IdentityHub, IssuerService and Portal service links use plain HTTP inside the cluster. They are covered by NetworkPolicies only where the chart defines them. | overlay |
| S-07 | The DEV IdentityHub STS client secret (`iatp.sts.oauth.client.secret`) is a short, guessable value, and its Vault alias name is derived from it. The DEV Vault tooling names that alias in a policy path. Use a strong random secret on the target, together with an alias that does not reveal it. Consider the DEV value exposed. | in-memory comparison 2026-11-02 (value not recorded) |
| S-06 | Plaintext credentials remain in untracked files of the source checkout (DEV values stack, `values-callback-activation.yaml` history). Nothing from those files was copied. | in-memory comparison: 0 DEV credentials in this package |
