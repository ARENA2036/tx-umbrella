# BE-293 Contribution Attribution

**Audit date:** 2026-11-02.

**Method:** read-only Git inspection of the local repositories, plus read-only GitHub API queries. No source, chart or cluster was changed.

**Purpose:** record which BE-293 technical changes were implemented by ARENA2036, by Federity-X, or inherited from Eclipse Tractus-X upstream, and which cannot be attributed. Deployment activity is kept separate from authorship.

## How attribution was decided

- **Author identity.** Authors are identified by **commit author and committer email domain**. Each address is pseudonymized to a stable ID (the first 4 hex characters of the SHA-256 of the address). No names or addresses appear here.

  | ID | Domain | Role in evidence |
  |---|---|---|
  | **A1** | arena2036.de | BE-293 integration commits in ARENA2036 repositories |
  | **A2** | arena2036.de | ARENA2036 Portal Backend maintenance and merges; upstream IdentityHub contributions |
  | **A3** | arena2036.de | ARENA2036 deployment work; upstream IdentityHub test collection |
  | **F1** | technovativesolutions.co.uk | Principal BE-293 implementer in the Federity-X repositories |
  | **F2, F3** | technovativesolutions.co.uk | Federity-X CI and upstream-sync work |
  | **U** | various (cofinity-x.com, t-systems.com, GitHub no-reply, …) | Eclipse Tractus-X upstream contributors |

- **Organization.** A change is attributed to **Federity-X** when its commits were made by Federity-X contributors (the F IDs above) **and** were pushed to Federity-X branches or opened as Federity-X pull requests. An email domain alone is not treated as proof of affiliation; it is supported by the push and PR evidence. A change is attributed to **ARENA2036** when an `arena2036.de` author committed it, in either organization's repository.
- **Repository location never decides authorship.**
- **Patch IDs** (`git patch-id --stable`) and commit-object identity were used to detect copies and cherry-picks.
- **Uncommitted and untracked files** carry no Git authorship. They are classified **Unknown**. File modification times are given only as weak context.
- **AI assistance.** Some commits carry a `Co-Authored-By` trailer for an AI coding assistant: 6 on the Federity-X Umbrella branch (5 by A1, 1 by F1) and 1 ARENA handoff commit. This affects neither the organizational attribution nor the responsibility of the committing author.
- **PR history.** The ARENA2036 GitHub organization rejected API access for the available token (organization token-lifetime policy). ARENA2036 pull-request history therefore could not be inspected; ARENA attribution rests on Git history only.

## Executive summary

1. **Federity-X implemented the core BE-293 functionality.**
   - The IdentityHub/IssuerService dual-wallet Umbrella chart (the code that became Umbrella 3.17.0).
   - The IdentityHub `portal-credential-callback` extension.
   - The Portal Backend IdentityHub/IssuerService onboarding wallet provider.
   - The DTR `sortDirection` feature.

   Evidence: 73 + 27 + 19 + 1 commits by F1, on Federity-X branches and draft PRs (Umbrella #2, IdentityHub #4, Portal Backend #9; upstream DTR #616).
2. **ARENA2036 implemented the BE-293 integration and hardening work.**
   - The EDC Connector 0.13.0 GA migration and fail-closed SecretRef patches.
   - The DTR TLS values fix, the Wallet stub ingress fix, and the dependency locks.
   - An independent Portal-chart IdentityHub SecretRef patch.
   - The Portal OIDC claim-name fix.
   - The Portal Connector-provisioning API with its EF migration.
   - DEV recovery tooling and the end-to-end acceptance record.
   - The recovered 3.17.0 baseline and this handoff package.

   Evidence: A1 commits in ARENA2036 repositories, plus 5 unpushed A1 commits in the Federity-X Umbrella working copy.
3. **ARENA2036 integrated Federity-X's Portal Backend work unchanged.** A2 merged the 19 Federity-X commits into ARENA (`939dec7`, 2026-10-14) as **identical commit objects**, with no rewrite or cherry-pick.
4. **Two pieces of work were done twice:**
   - The OIDC fix exists in both Portal Backend repositories with the same patch ID, committed by A1 both times.
   - The Portal-chart IdentityHub wiring was implemented separately by F1 (Federity-X patch) and by A1 (ARENA patch), over the same environment-variable contract.
5. **Much of what DEV actually runs cannot be attributed.** The DEV-specific hardening of the 3.17.0 chart was never committed:
   - guard templates, seed and Vault-setup rewrites, 25 chart and image patches, the 18-file values stack;
   - the Connector Provisioner controller;
   - several image-build patches.

   These files are dated 2026-10-14 to 2026-10-28, after the last Federity-X commit on the branch (2026-08-07). Git does not show who wrote them.
6. **ARENA2036 also contributed upstream.** Thirteen ARENA-authored commits, including an IdentityHub frontend, are in Eclipse Tractus-X IdentityHub `main`, and therefore in the base of the deployed IdentityHub image.
7. **Inherited from upstream:** the EDC source used for the DEV images (`72755ae`, upstream PR #2932), the DTR pagination fix (upstream PR #604), and the base Umbrella, Portal and BPDM releases.

## Contribution table

| Component | Feature / Change | Original Source | Implemented By | Integrated By | Evidence | Confidence |
|---|---|---|---|---|---|---|
| Umbrella chart | Dual-wallet support and 10-step DCP seeding Job | Federity-X `public-tractus-x-umbrella` | **Federity-X** (F1) | ARENA (A1), through the recovered 3.17.0 baseline | `5ec5cdb`, `41977c1`, `2fdac40`, `d1f39e9`; branch `feat/BE-293-connector-bundle-and-portal-integration`; Federity-X PR #2 (draft, head `13cfd0f`) | High |
| Umbrella chart | End-to-end DCP with IdentityHub wallet; chart version 3.17.0 introduced | Federity-X | **Federity-X** (F1) | ARENA (A1): `60c0b81`, `c5ec396`, `3e614d0` | `c9e3e2d` (2026-06-20) adds `version: 3.17.0` | High |
| Umbrella chart | IssuerService on PostgreSQL, CoreDNS patch Job, STS and BDRS routing fixes | Federity-X | **Federity-X** (F1) | ARENA (A1) via the baseline | `4e1ab93`, `e952817`, `e86d357`, `13bb25f` | High |
| Umbrella chart | Durability: persistent IdentityHubs, Raft Vaults, PostgreSQL BDRS, Submodel persistence | Federity-X | **Federity-X** (F1) | ARENA (A1) via the baseline | `52fb7ae`, `15fd132`, `b747f67`, `556b110`, `e0eebd9` | High |
| Umbrella chart | Portal onboarding and credential-callback wiring; wallet-provider selector; BE-324 fixes | Federity-X | **Federity-X** (F1) | ARENA (A1) via the baseline | `9c11053`, `d8e6ae9`, `a56735e`, `062d1ce`, `4de576e`, `13cfd0f` | High |
| Umbrella chart | DEV hardening of 3.17.0: `_wallet-validate` guard (+172 lines), wallet-derive/mode, BDRS provision template and NetworkPolicy, seed hook (+279/−59), Vault-setup rewrite | Uncommitted Federity-X working tree | **Unknown** | ARENA (A1), recovered into Git by `60c0b81` | `git status` of the source checkout: 33 modified and 301 untracked files, mtime 2026-10-14 to 2026-10-28. No commit. | — |
| Umbrella chart | 25 upstream-chart and image patches (Keycloak seeding recovery, secret-preserve, Connector rc2 secret env, IdentityHub/IssuerService runtime secrets, BDRS secrets, Portal connector provisioning) | Uncommitted | **Unknown** | Vendored, already applied, into the ARENA baseline (`60c0b81`) | `hack/patches/*` untracked, mtime 2026-10-14 to 2026-10-27 | — |
| Umbrella chart | DEV values stack (18 files, `hack/be293-k8s-dev-01-g7-values.json`) | Uncommitted | **Unknown** | ARENA (A1): sanitized overlay `60c0b81` | 13 untracked and 2 modified files | — |
| Umbrella chart | DEV recovery tooling: Vault recovery, gated seeding runner, StatusList recovery, DCP routing preflight, EDC acceptance, end-to-end success record | Federity-X working copy, local commits | **ARENA2036** (A1) | — (not pushed) | `a0ced70`, `30fecdd`, `3feb77c`, `6279ce9`, `a5b07c5`. Local only: 5 ahead of `origin/feat/BE-293-…`. These files have further **uncommitted** edits, which are Unknown. | High (committed parts) |
| Umbrella chart (ARENA line) | EDC Connector 0.11.1 → 0.13.0 GA, DCP/DIV values, fail-closed Connector SecretRef patch, Provider Vault-setup SecretRefs | ARENA2036 `tx-umbrella` | **ARENA2036** (A1) | ARENA (A1) | `2f4add9`, `5084a38`, `2b95a94`; `hack/patches/tractusx-connector-0.13.0-secret-refs.patch` | High |
| Umbrella chart (ARENA line) | DTR TLS values fix | ARENA2036 | **ARENA2036** (A1) | ARENA (A1) | `bbf007f` (separate clone), re-applied in `ba291ab` | High |
| Umbrella chart (ARENA line) | Wallet stub 0.1.14 TLS ingress patch; nested chart locks | ARENA2036 | **ARENA2036** (A1) | ARENA (A1) | `bd2d615`, `e85316a` | High |
| Umbrella chart (ARENA line) | Recovered and sanitized 3.17.0 baseline, sanitization tooling, validation report | ARENA2036 (packaging of Federity-X plus Unknown content) | **ARENA2036** (A1) for the packaging. Chart content is per the rows above. | ARENA (A1) | `c5ec396`, `3e614d0`, `60c0b81`; `recovery/be293-dev-3.17.0/` | High (packaging) |
| Umbrella chart (ARENA line) | Tests, acceptance helper, runbooks, audit report, handoff package | ARENA2036 | **ARENA2036** (A1) | ARENA (A1) | `a8213d7`, `995704d`, `df91837`, `2b3e27c`; `hack/tests/*`, `hack/be293_edc013_acceptance.py` | High |
| Portal chart (Helm patch) | IdentityHub onboarding settings for Portal 2.6.0 (`APPLICATIONCHECKLIST__IDENTITYHUB__*`, `ONBOARDING__WALLETPROVIDER`) | Federity-X | **Federity-X** (F1) | Deployed on DEV via the 3.17.0 chart | `hack/patches/portal-2.6.0-be293-identityhub.patch` tracked: `9c11053` → `13cfd0f` | High |
| Portal chart (Helm patch) | Same contract, opt-in `portal.backend.identityHub.*`, HTTPS-only, external SecretRefs | ARENA2036 | **ARENA2036** (A1) | Not deployed | `cfe6084`, `hack/patches/portal-2.6.0-identityhub-secret-refs.patch`. 15 env names are shared with the Federity-X patch; the values schema differs; 36 of 112 added lines overlap. | High: **independent duplicate** |
| Portal chart (Helm patch) | `identityHub.existingSecret` (shared super-user Secret) | Uncommitted edit of the Federity-X patch | **Unknown** | Optional overlay in the handoff (A1) | Patch modified 2026-10-28, uncommitted | — |
| Portal Backend | IdentityHub + IssuerService as onboarding wallet provider (IdentityHub library, issuer component, BPN-DID resolver, checklist steps, EF migration `20260710175010_BE293IdentityHubWalletStepTypes`), including BE-324 fix `0421c50` | Federity-X `public-portal-backend` | **Federity-X** (F1) | **ARENA2036** (A2): merge `939dec7` (2026-10-14), follow-up `b69c967` | 19 commits, `fa5675c..0421c50`; Federity-X PR #9 (draft, head `0421c50`). The ARENA commits are the same objects (19/19 identical SHAs). | High |
| Portal Backend | OIDC claim-name fix (`MapInboundClaims=false`) and tests | ARENA2036 author, first committed in the Federity-X working copy | **ARENA2036** (A1) | ARENA (A1): `694fef5` into `feat/BE-293-portal-integration` | `933aeeb25` (Federity-X fork, local only, 2026-10-20) and `b824dfe7f` + `77ce402b` (ARENA, 2026-10-28). Same patch ID `7ce63d54fcb6`. | High: **duplicated across repositories** |
| Portal Backend | Connector-provisioning requests API, roles, EF migration `20261024150921_BE293ConnectorProvisioningRequests` | ARENA2036 | **ARENA2036** (A1) | ARENA (A1): `ec9d005`; a DEV image was built from an earlier uncommitted variant | `a642c76e`, `064b0d53`. The earlier variant exists only as an untracked patch and uncommitted tree in the Federity-X fork (author Unknown; it differs from the commit in 3 files). | High (commit); Unknown (DEV image source) |
| Portal Backend | Processes-worker image hardening (`security2`: Dockerfile and csproj) | Untracked patch | **Unknown** | Deployed on DEV | `hack/patches/portal-processes-worker-security2.patch`, untracked | — |
| Portal Backend | ARENA branding and e-mail templates (pre-BE-293) | ARENA2036 | **ARENA2036** (A2; an earlier contributor with a cgi.com address) | ARENA | `43767079`, `0830b85`, `e800939` | High |
| IdentityHub / IssuerService | `portal-credential-callback` extension (holder-side observer posting the Portal issuer callback) plus chart, docs and CI fixes | Federity-X `public-tractusx-identityhub` | **Federity-X** (F1) | Deployed on DEV (image `identityhub-3633af-r1`) | 27 commits `d5d5ee6..3633af6`, extension `b6b5acc..3633af6`; Federity-X PR #4 (closed, unmerged draft) | High |
| IdentityHub / IssuerService | IdentityHub frontend (UI), participant-context fix for Docker, header, naming and dependency updates, Bruno e2e collection | **Eclipse Tractus-X upstream**, contributed by ARENA2036 authors | **ARENA2036** (A2, A3), upstream contribution | Inherited by the deployed image: all 13 commits are ancestors of `3633af6` through upstream `main` `d5d5ee6` | `9a8de22`, `d54904b`, `5b330c0`, `d40d27a`, `07a6ce7`, `9caeff2`, `8683eaf`, `3cb0f41`, `d5aa98c`, `80b3458`, `552eb08`; merges `ac154a7` ("Merge pull request #1 from ARENA2036/feature/frontend") and `747089e`. `9a8de22` and `d5d5ee6` were verified present in `eclipse-tractusx/tractusx-identityhub` through the GitHub API. Whether the UI ships in the runtime image was not checked. | High (authorship); Medium (runtime relevance) |
| IdentityHub / IssuerService | IssuerService `keypair-api` build patch | Untracked | **Unknown** | Deployed (`issuerservice-3633af-r1`) | `hack/patches/identityhub-0.3.2-issuerservice-keypair-api.patch` | — |
| IdentityHub / IssuerService | `sts-account-secret-api` extension | Uncommitted worktree | **Unknown** | Not deployed | `extensions/identityhub/sts-account-secret-api/` untracked (4 modified, 1 untracked) | — |
| EDC | Source of the DEV control-plane and data-plane images | Eclipse Tractus-X | **Upstream** | Image build: Unknown | `72755ae` is in `eclipse-tractusx/tractusx-edc` (PR #2932); Federity-X `main` mirrors upstream (36 of the last 40 commits carry upstream PR references) | High |
| EDC | Connector 0.13.0-rc2 chart patches (secret env, Vault secret env, test identity) | Untracked | **Unknown** | Vendored in DEV `tx-data-provider` 0.5.0 | `hack/patches/tractusx-connector-0.13.0-rc2-*.patch` | — |
| DTR | Pagination fix for upstream issue #603 | Eclipse Tractus-X contributor | **Upstream / third party** (U, t-systems.com) | Federity-X branch base (F1) | `8359d9c`, `5a7f24e`; upstream PR #604 | High |
| DTR | Optional `sortDirection` on `GET /shell-descriptors` | Federity-X `public-sldt-digital-twin-registry` | **Federity-X** (F1) | Deployed (`digital-twin-registry-9ac65a-r1`) | `9ac65a3`; upstream PR #616 (open) | High |
| Connector Provisioner | Controller (Python), Dockerfile, tests, Helm chart, CRD, values, Portal provisioning tooling | Uncommitted, in the Federity-X working tree | **Unknown** | Deployed on DEV (`be293-connectors`) | `connector-provisioner/**`, `charts/connector-provisioner/**`, `hack/portal-provisioning/**` untracked, mtime 2026-10-23 to 2026-10-27 | — |
| Image publication | Private DEV image builds and the publication manifest | Untracked | **Unknown** | Deployed | `hack/be293-dockerhub-publication.yaml`, lock files untracked. The registry account name was not used as evidence. | — |
| CI / repository hygiene | Upstream-sync workflows in the Federity-X forks | Federity-X | **Federity-X** (F2, F3) | — | Federity-X Umbrella PR #1 (`b8c3370`), Portal Backend PR #1, IdentityHub PR #1 | High |
| Base platform | Umbrella 3.14.0, Portal 2.6.0, BPDM 6.2.0 / 7.2.0, Keycloak charts, Discovery, SD-Factory | Eclipse Tractus-X | **Upstream** | ARENA `develop` (various ARENA authors, pre-BE-293) | tag `umbrella-3.14.0` = `d46d078`; Portal base `v2.6.0-18-gfa5675c` | High |

## Verified ARENA2036 contributions (BE-293)

- **EDC Connector 0.13.0 GA migration.** DCP/DIV values, a fail-closed Connector SecretRef patch, and Provider Vault-setup SecretRefs: `2f4add9`, `5084a38`.
- **Chart fixes.** DTR TLS values fix (`bbf007f`, `ba291ab`), Wallet stub ingress patch (`bd2d615`), dependency locks (`e85316a`).
- **Opt-in Portal-chart IdentityHub SecretRef patch:** `cfe6084`. Independent of the Federity-X patch.
- **Portal Backend.**
  - OIDC claim-name fix with tests: `b824dfe7f`, `77ce402b`; also `933aeeb25` in the Federity-X fork.
  - Connector-provisioning requests API with EF migration: `a642c76e`, `064b0d53`.
- **DEV recovery and acceptance tooling.** Committed locally in the Federity-X working copy, never pushed: `a0ced70`, `30fecdd`, `3feb77c`, `6279ce9`, `a5b07c5`.
- **Integration of the Federity-X Portal Backend work** into ARENA2036 (A2): `939dec7`, `b69c967`.
- **Upstream Eclipse Tractus-X IdentityHub contributions**, before BE-293 integration: the IdentityHub frontend, a participant-context fix, maintenance commits and a Bruno e2e collection (A2, A3; 2026-05-13 to 2026-06-09, 13 commits). They are part of the upstream base `d5d5ee6` of the deployed IdentityHub image.
- **Recovered and sanitized 3.17.0 baseline, validation, documentation, tests and this handoff:** `c5ec396`, `3e614d0`, `60c0b81`, `a8213d7`, `995704d`, `df91837`, `2b3e27c`.

## Verified Federity-X contributions (BE-293)

- **Umbrella dual-wallet and IdentityHub/IssuerService integration**, from seeding through durability to the Portal-onboarding wiring. This is the chart that became 3.17.0. There are 73 F1 commits (2026-04-17 to 2026-08-07); Umbrella PR #2 (draft).
- **Portal 2.6.0 chart IdentityHub patch:** tracked `hack/patches/portal-2.6.0-be293-identityhub.patch`.
- **Portal Backend IdentityHub + IssuerService onboarding wallet provider**, including the BE-324 crash fix: 19 commits; Portal Backend PR #9 (draft).
- **IdentityHub `portal-credential-callback` extension:** 27 commits; IdentityHub PR #4 (closed, unmerged).
- **DTR `sortDirection` feature:** `9ac65a3`; upstream PR #616.

## Shared, duplicated or parallel work

| Item | Nature | Evidence |
|---|---|---|
| Portal Backend IdentityHub wallet | Federity-X implementation; ARENA integration (no rewrite) | 19/19 identical commit objects; ARENA merge `939dec7` |
| Portal OIDC claim-name fix | The same change committed in both organizations' repositories, by A1 | Patch ID `7ce63d54fcb6` (`933aeeb25` and `b824dfe7f`) |
| Portal-chart IdentityHub patch | **Parallel implementations** of the same Portal environment contract (F1: `processesworker.identityHub.*`, internal HTTP allowed; A1: `identityHub.*`, HTTPS-only, SecretRefs). They are incompatible, as recorded in the deployment report. | 15 shared env names; 36 of about 110 added lines overlap |
| Umbrella 3.17.0 baseline | Federity-X chart, plus unattributed DEV hardening, recovered and packaged by ARENA | `c9e3e2d` … `13cfd0f` (F1), uncommitted tree, `60c0b81` (A1) |
| Connector provisioning | The Portal API side is ARENA-committed. The DEV image was built from an earlier uncommitted variant in the Federity-X working copy. The controller is unattributed. | `a642c76e`; `portal-backend-933aeeb-connector-provisioning.patch` (untracked) |

## Unattributed changes (no Git authorship)

All of these exist only as uncommitted or untracked files in the local Federity-X working copies. Their modification times are 2026-10-05 to 2026-10-28, which is after the last Federity-X commit on the branch (2026-08-07) and overlaps the A1 commit dates. This is context only, not proof.

1. 33 modified tracked files in `public-tractus-x-umbrella`: chart templates, `tx-data-provider` hooks, values, `helm-dependencies.bash`, DEV tooling.
2. 301 untracked files there:
   - 25 chart and image patches;
   - the 18-file DEV values stack;
   - Connector Provisioner source, chart and CRD;
   - Portal provisioning tooling;
   - about 195 `hack/` scripts;
   - 44 `docs/dev` files.
3. The IdentityHub `sts-account-secret-api` extension and its build-wiring changes.
4. The image-build provenance: publication manifest, lock files, the `r1`/`r3` image builds and the private registry pushes.
5. Live DEV actions: Helm upgrades, manual Jobs, Vault and Ingress changes. Helm release records do not record an actor, and these are deployment actions, not authorship.

Making these attributable requires the contributors to commit them, with correct authorship, to an agreed repository.

## Component-level contribution matrix

| Component | Upstream base | Federity-X | ARENA2036 | Unknown |
|---|---|---|---|---|
| Umbrella chart | 3.14.x | **Primary implementation** (wallet, IdentityHub/IssuerService, seeding, durability, onboarding wiring, 3.17.0) | EDC 0.13 GA migration, SecretRefs, fixes, locks, recovery and packaging, tests and docs | DEV hardening templates, 25 patches, values stack |
| EDC Connector | **Source** (0.13.0-SNAPSHOT `72755ae`; 0.13.0 GA) | Fork mirror only | 0.13.0 GA chart migration and SecretRef patch (not deployed) | rc2 chart patches, image builds |
| IdentityHub / IssuerService | 0.3.2 (upstream `main` `d5d5ee6`, which includes ARENA2036-authored upstream commits) | **`portal-credential-callback` extension**, charts | Upstream contributions (frontend, fixes; A2, A3) | keypair-api patch, `sts-account-secret-api`, runtime-secret chart patches |
| BDRS | 0.6.0 | PostgreSQL BDRS overlay and seeding (`b747f67`, `56a5984`) | — | BDRS secrets patch |
| Portal Backend | v2.6.0+18 | **IdentityHub/IssuerService onboarding wallet**, BE-324 fix | OIDC fix, Connector-provisioning API and migration, integration merge | processes-worker hardening patch, image builds |
| Portal chart | 2.6.0 | **IdentityHub patch** (deployed) | Independent SecretRef patch (not deployed) | `existingSecret` edit, connector-provisioning and secret-preserve patches |
| Central / Shared IDP, BPDM, SD-Factory | 4.2.1 / 6.2.0 / 2.1.35 | — | — | Seeding recovery, TLS, secret-preserve patches |
| DTR | 0.10.0 (+ upstream #604 fix) | **`sortDirection`** | TLS values fix (integration line) | — |
| Submodel server | upstream | PostgreSQL persistence (`556b110`) | — | DEV image source snapshot |
| Connector Provisioner | — | — | Portal API side only | **Controller, chart, CRD, tests** |
| Documentation, tests, handoff | — | 1609 and BE-293 guides (F1) | Runbooks, acceptance, audit, handoff (A1) | 44 uncommitted `docs/dev` files |

## Neutral summary for team discussion

- **Federity-X built the BE-293 feature set.** That covers the Umbrella dual-wallet chart with IdentityHub and IssuerService, the IdentityHub-to-Portal credential callback, the Portal Backend IdentityHub/IssuerService wallet provider, and the DTR `sortDirection` feature. All of it is committed and visible as Federity-X draft pull requests.
- **ARENA2036 integrated it.** ARENA2036 merged the Portal Backend work unchanged, prepared the EDC 0.13 GA migration with SecretRef hardening, fixed the DTR TLS and Wallet stub ingress issues, added the OIDC fix and the Connector-provisioning API, and recovered, documented, validated and packaged the DEV baseline.
- **Two areas need agreement:**
  - The Portal-chart IdentityHub configuration exists in two incompatible versions, one per organization. Choose one.
  - A large amount of DEV-specific work has no commit history: chart hardening, patches, the values stack, the Connector Provisioner and the image builds. It cannot be attributed or reviewed until its authors commit it.

Agreeing on one canonical repository and committing that work, with correct authorship, would settle both ownership and reproducibility.

## Limitations

- ARENA2036 pull-request history could not be read (organization token policy). PR references are given for Federity-X and upstream only.
- Organizational affiliation rests on email domain combined with push and PR evidence in the organization's repositories.
- On the Federity-X remotes, `arena2036.de`-authored commits appear **only** in IdentityHub, and only through upstream Eclipse `main` (13 commits, verified upstream). They are not Federity-X branch work. A1's Federity-X-side commits (Umbrella, Portal Backend) were never pushed.
- File modification times are not evidence of authorship.
- Commit authorship shows who recorded a change. It does not show who designed it, or who reviewed it outside Git.
