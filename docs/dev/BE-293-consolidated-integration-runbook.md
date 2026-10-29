# BE-293 Consolidated Integration Runbook

## Purpose and current branch

This runbook describes the local Connector 0.13.0 integration candidate on branch
codex/be293-edc-013-dtr-integration. It is a plan and validation record, not a
deployment authorization or proof of current DEV functionality.

The Umbrella candidate preserves established DID/BPN/context mappings in the
tracked values and migrates Connector configuration from IATP to DCP/DIV. The
separate acceptance helper is offline-only. No Kubernetes, Vault, database, or
live identity checks were performed for this checkpoint.

## Component boundaries

| Component | Location in this candidate | Integration status |
|---|---|---|
| EDC Provider and Consumers | Umbrella Connector bundle, three values aliases | Connector chart 0.13.0 is pinned. Profiles preserve configured participant identifiers and use DCP/DIV variable names. |
| DTR and Submodel | Umbrella digital-twin bundle and data-persistence bundle | Existing DTR TLS values correction is included. DTR remains chart 0.9.0, not the 26.09 matrix version. |
| Wallet | Umbrella identity-and-trust bundle | This deploys ssi-dim-wallet-stub 0.1.14, not a demonstrated production Holder Wallet integration. Its pinned TLS ingress patch is included. |
| IdentityHub | Separate BE-293 IdentityHub chart/repository and Helm release | It is not an Umbrella dependency. Do not add a second IdentityHub to the Umbrella. The BE-293 IdentityHub and IssuerService chart source currently has uncommitted work; use only reviewed immutable chart/image artifacts in a future deployment. |
| Tractus-X IssuerService | Separate chart/repository and release | Not the same component as Umbrella dependency ssi-credential-issuer 1.4.0, which is present in the production profile. |
| Portal | Umbrella Portal chart plus separate Portal Backend application repository | Portal Backend branch feat/BE-293-portal-integration at f5badda90030531434c9445e5bb4b70382bea6eb contains the OIDC claim mapping and Connector provisioning API/database migration changes. The Umbrella branch does not build or publish that application image or apply its database migration. |
| Connector provisioning controller | Separate, incomplete work in the dirty public Umbrella checkout | Not integrated into this clean candidate. Its chart/controller, CRD, identity, Secret, RBAC, image and namespace decisions are not approved or reproducible here. Do not copy the dirty checkout as a release artifact. |
| Keycloak | Central and Shared IDP Umbrella dependencies | Their presence does not make external DID/IssuerService or Portal identity state part of this Helm release. Persisted clients, realms, users and federation must be separately backed up and reviewed. |
| Vault and PostgreSQL | Connector bundle dependencies and component-specific databases | Their chart topology is unresolved. Do not change versions, persistent volumes, or database contents before the data/platform owners approve a topology and rehearsed migration plan. |

### IdentityHub and connector contracts

The historical BE-293 runtime contract used IdentityHub STS at port 8087
(path /api/sts/token), Credential Service at port 8083
(path /api/credentials/v1/participants/{participantId}), and public DID
documents through the DID service on port 8084. These are prior environment
findings, not live-verified endpoints for this branch. Confirm actual Service
names, ports, TLS, and version from the approved deployed IdentityHub release
before configuring a Connector.

The Umbrella values currently point Connector test profiles at the Wallet stub:
the STS token URL uses its OAuth token route and the 0.13 credential-service
variable is TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL with the stub API base. The
production values use the stub's configured HTTPS public base. They do not
currently point to the separately deployed IdentityHub. Configure a Connector
to IdentityHub only after the identity operator confirms exact internal
STS/Credential Service routes and service identity. Keep public DID resolution
on the verified HTTPS DID URL; do not replace the issuer identity with a
service-cluster URL.

The 0.13 migration keeps the existing DID as participant.id, BPN as
participant.bpnl, and the pre-existing contextId. Regression tests compare DID
values to the clean baseline and validate UUID shape/uniqueness in checked
profiles. They do not verify that these values match persisted DEV
ParticipantContexts or deployment identities. The identity owner must confirm
that match before rollout.

Configured trust material and credential requirements must be derived from
actual Provider access/usage policies. The offline acceptance tests use
MembershipCredential, BpnCredential, and DataExchangeGovernance as metadata
fixtures; they do not validate signatures, proof purposes, issuer trust, status
lists, or live Wallet contents. The Portal role view_company_data is a Portal
authorization concern, not a substitute for EDC DCP credential checks.

## Chart and profile validation record

Dependency locks pin the currently declared charts, not a complete 26.09
Umbrella baseline. The locked graph includes Connector 0.13.0, DTR 0.9.0,
BPDM chart 6.2.0, Wallet stub 0.1.14, and other existing component pins. The
published 26.09 component matrix is a constraint, not an Umbrella lock. The
current Umbrella does not include the separate IdentityHub chart.

For the render inventories below, Secret references were supplied as synthetic
names and keys in process memory. No Secret payloads were rendered or reported.

- Three-connector EDC validation profile: 180 rendered objects, 18 kinds,
  including three Control Plane and three Data Plane Deployments. It includes
  DTR/Submodel and Wallet stub. Portal, Central/Shared IDP, BPDM and IdentityHub
  are absent by profile.
- Production profile: 276 rendered objects, 20 kinds, including two Control
  Plane and two Data Plane Deployments; Consumer 2 is disabled by that profile.
  Portal, Central/Shared IDP, ssi-credential-issuer, BPN Discovery, DTR and
  Wallet stub are rendered. BPDM and IdentityHub are absent.
- Both raw renders contain repeated Pod definitions named
  controlplane-with-token-auth-test. They carry the Helm test hook annotation,
  not a normal workload hook. The chart sets before-hook-creation and
  hook-succeeded deletion policy. These are test-hook definitions, not three
  running Pods. Helm test was not run against a cluster.
- The earlier 240-object total cannot be reproduced from a preserved exact
  command and values set. The counts above are from the explicit stacks named
  here and an in-memory inventory parser; they are not a live-resource diff.
- Rendered charts contain cluster-scoped resources, including RBAC, CRDs and
  admission webhooks. The counts are 43 in the three-connector profile and 39
  in production. Any deployment requires a separate cluster-scope review.
- Per-kind EDC inventory: ClusterRole 16; ClusterRoleBinding 16; ConfigMap 18;
  CRD 6; Deployment 15; Ingress 9; Issuer 1; Job 5; MutatingWebhookConfiguration
  4; NetworkPolicy 4; Pod 11; Role 5; RoleBinding 5; Secret 8; Service 31;
  ServiceAccount 17; StatefulSet 8; ValidatingWebhookConfiguration 1.
- Per-kind production inventory: ClusterRole 15; ClusterRoleBinding 14;
  ConfigMap 24; CronJob 5; CRD 6; Deployment 27; Ingress 18; Issuer 1;
  Job 10; MutatingWebhookConfiguration 3; NetworkPolicy 8; Pod 10;
  PodDisruptionBudget 4; Role 7; RoleBinding 7; Secret 29; Service 55;
  ServiceAccount 18; StatefulSet 14; ValidatingWebhookConfiguration 1.

The main Umbrella chart disables the Connector chart's own optional PostgreSQL
and Vault dependencies but the enclosing dataspace-connector-bundle separately
enables Bitnami PostgreSQL 15.2.1 and Vault 0.27.0. DTR and other components
also have database dependencies. The actual DEV topology, PVC ownership,
backup/restore procedure, and federated-catalog retention decision are not
proven by local rendering. The migration guide notes the old
edc_federated_catalog data migration/removal; the data owner must decide
preserve/export versus discard and rehearse the chosen route on a disposable
database.

## Secret and identity safety gates

The Connector chart patch is pinned to 0.13.0 and reads management API key,
Data Plane proxy key, external database password, and Vault token through
required Kubernetes Secret references. The Provider Vault setup Job also reads
its Vault token, key material, and seed payload through required Secret
references and read-only mounts. Rendering fails when required references are
absent. Synthetic reference names used for local render do not establish the
existence, ownership, content, or policy of any real Secret.

The old private-key/AES material remains in Git history and existing
credential-bearing values. SecretRef rendering does not erase historical
exposure or classify those keys as disposable. Security-owner classification
and any history response remain publication gates. Do not copy credential
values into this branch or rotate existing identities.

The Portal Backend branch adds an EF migration for provisioning request data.
It has not been applied here. Require a reviewed backup, migration rehearsal,
image provenance, Portal authorization validation, and separately authorized
database change before using that branch in an environment.

## Required decisions before DEV acceptance

1. Identity owner: confirm persisted Provider/Consumer DIDs, BPNs, canonical
   context IDs, issuer DID, DID documents, signing keys, and credential types.
   Preserve them; never regenerate values to satisfy a render.
2. Security/infrastructure: classify historical key material; define each
   SecretRef name/key, provisioning owner, Vault policy, token lifetime and
   renewal behavior. No current Secret payload comparison is claimed.
3. Database/platform owner: confirm PostgreSQL and Vault topology and PVC
   ownership; decide federated-catalog retention; approve a disposable rehearsal
   and recovery point before any database migration.
4. Release owner: provide the complete approved 26.09 component/version
   baseline. Current DTR, BPDM and Wallet/Issuer component pins are not evidence
   of a complete 26.09 release.
5. Identity/platform owner: provide immutable, reviewed IdentityHub and
   Tractus-X IssuerService chart/image artifacts and endpoint contracts; confirm
   they remain separate releases and Umbrella values do not install a duplicate
   IdentityHub.
6. Portal owner: build and test the Portal Backend integration branch and
   review its EF migration and API roles. Decide whether and how the separate
   Connector-provisioning controller is packaged and operated.

## Safe deployment order after approvals

1. Freeze reviewed chart versions and values; resolve the gates above.
2. Prepare backups and rehearse database migration/restore in an isolated
   environment. Do not combine database changes with a Helm rollback plan.
3. Provision exact runtime Secrets and least-privilege Vault access through the
   approved owner; validate references and capabilities without displaying
   payloads.
4. Deploy or validate the existing IdentityHub and Tractus-X IssuerService
   releases separately. Do not add duplicate copies under Umbrella.
5. Verify participant contexts are ACTIVE, exact DID documents are PUBLISHED,
   HTTPS validation succeeds, issuer metadata is correct, and required
   credentials can be issued and verified.
6. Validate BDRS/DID mappings and DTR/Submodel data against approved existing
   identifiers. Do not reseed or overwrite identity material.
7. Deploy the reviewed EDC Connector 0.13 profile with confirmed IdentityHub,
   issuer, DID, Vault, database and Secret references.
8. Deploy the separately reviewed Portal Backend image and apply its database
   migration only in an authorized window. Validate Keycloak claim mapping,
   Portal roles and company/IdP association.
9. Run functional acceptance with approved synthetic data and protected
   credentials. Stop on the first unexpected error; do not automatically repeat
   non-idempotent operations.

## Acceptance checklist

### Identity and Wallet
- Confirm Provider and Consumer contexts and issuer context are ACTIVE.
- Resolve each approved DID URL over verified HTTPS and validate document ID,
  verification method/controller, and service endpoint consistency.
- Obtain or inspect required credential metadata without printing credential
  bodies; verify signatures, issuer trust, holder binding, status and expiry in
  the actual DCP exchange.

### EDC
- Confirm Connector version, participant DID/BPN/context, trusted issuer,
  management and DSP endpoint configuration.
- Discover Provider DSP version/address; for DSP 2025-1 the expected
  protocol suffix is /api/v1/dsp/2025-1 and protocol
  dataspace-protocol-http:2025-1, subject to live DID discovery.
- Make a bounded Catalog request and require the expected dataset and Offer.
- Negotiate only from the discovered Offer and require FINALIZED plus an
  agreement ID.
- Request the advertised transfer type; for the synthetic HTTP pull test use
  HttpData-PULL.
- Retrieve data through the approved protected EDR/proxy path and compare the
  actual received bytes with the fixed synthetic fixture. An HTTP 2xx, catalog
  response, finalized contract, or transfer STARTED state alone is not success.

### Portal
- Complete a fresh browser login through Central IDP and any configured
  federation.
- Verify authenticated company identity and the minimum Portal role.
- Require the real authenticated ownCompanyDetails request to return 2xx and
  /home to render. Do not use an unauthenticated request as evidence.

The local acceptance helper and tests build/check request contracts and compare
synthetic payload bytes. They do not call services. The historical DEV record
of a Provider-to-Consumer 1 transfer is evidence from a different, dirty and
non-reproducible checkout; it is not acceptance evidence for this clean branch.
No current Wallet, DID, Portal, Catalog, Negotiation, Transfer, or payload
acceptance was performed during this work.
