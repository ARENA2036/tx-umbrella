# BE-293 real IdentityHub, Portal, IssuerService, and Connector contract

This document records source-backed configuration contracts for the local
Connector 0.13 integration candidate. It does not select live service names,
participant identities, credential types, Secret names, or deployment values.

## Component boundaries

- The Umbrella `identity-and-trust-bundle` deploys `ssi-dim-wallet-stub`.
  The stub remains the default in all existing profiles. It is not the separate
  Tractus-X IdentityHub holder/credential service.
- The BE-293 IdentityHub and IssuerService are separate releases and their
  chart/source repositories are not dependencies of this Umbrella release.
- Portal Backend runs as separate Administration, Registration, and Processes
  Worker applications. The pinned Portal 2.6.0 chart supplies their Pods but
  does not contain the BE-293 IdentityHub application configuration until the
  version-pinned local patch is applied by `hack/helm-dependencies.bash`.
- The Connector Provisioner is separate from the Umbrella release and remains
  unintegrated. The BE-293 API in Portal Backend is not the provisioner
  controller.

## Portal onboarding wallet and IdentityHub settings

Portal Backend source defines `Onboarding:WalletProvider` and supports
`IdentityHub` as an enum value. All three onboarding deployables call
`AddOnboardingWallet`; therefore the chart emits
`ONBOARDING__WALLETPROVIDER=IdentityHub` to Administration, Registration, and
Processes Worker when the optional value is set.

Administration and Processes Worker additionally require the
`ApplicationChecklist:IdentityHub` section. The chart patch exposes these exact
configuration keys as `APPLICATIONCHECKLIST__IDENTITYHUB__...` environment
variables:

| Setting | Secret? | Contract |
|---|---:|---|
| `BaseAddress` | No | IdentityHub Identity admin API base, ending in `/api/identity`; use an internal service route with the chart-configured identity port. |
| `DidDocumentBaseLocation` | No | Host portion used to construct `did:web:{host}:{lowercased-bpn}`. Must match the DID published by the existing identity and resolve through BDRS. |
| `UniversalResolverAddress` | No | DIF resolver base used with `/1.0/identifiers/{urlEncodedDid}`. |
| `MaxValidationTimeInDays` | No | Required positive integer. |
| `CredentialServiceBaseAddress` | No | Holder DID service endpoint base ending in `/api/credentials`; Portal appends `/v1/participants/{participantContextId}`. |
| `IssuerDid` | No | Existing IssuerService DID. |
| `BpnCredentialType`, `BpnCredentialDefinitionId` | No | The credential type must exactly match the holder callback extension's configured BPN type; definition ID comes from the existing issuer definition. |
| `MembershipCredentialType`, `MembershipCredentialDefinitionId` | No | Same exact-type contract for Membership credentials. |
| `IssuerAdminBaseAddress` | No | Internal IssuerService admin API base ending in `/api/admin`; this endpoint must not be public. |
| `IssuerParticipantId` | No | Existing issuer participant context ID, used plain in the URL path. |
| `ApiKey` | **Yes** | IdentityHub admin API key, sent as `x-api-key`. |
| `IssuerAdminApiKey` | **Yes** | IssuerService admin API key, sent as `x-api-key`. |

The pinned Portal chart patch accepts the two API keys only through external
Kubernetes `secretKeyRef`s. It creates no credential Secret and stores no key
values in Helm values or release metadata. Integration remains disabled by
default. Enabling it requires all non-secret values and both external Secret
references; a partial configuration fails Helm rendering. Admin, Credential,
resolver, and Issuer Admin endpoint bases are required to use HTTPS; the chart
template rejects plaintext URL configuration.

Do not fill in these settings by copying the Wallet stub URL, inventing issuer
IDs, or choosing credential definition IDs. Confirm the exact in-cluster
service DNS name/fullname against the separately deployed release values and
current Service manifest; chart templates derive the Service name from the
release fullname.

## IdentityHub callback to Portal

The separate BE-293 `portal-credential-callback` extension is inert unless its
base URL is configured. It polls terminal holder credential requests and sends
Portal's existing BPN/Membership credential callback. Its confirmed settings
are:

- `TX_PORTAL_CALLBACK_BASE_URL`
- `TX_PORTAL_CALLBACK_TOKEN_URL`
- `TX_PORTAL_CALLBACK_CLIENT_ID`
- `TX_PORTAL_CALLBACK_CLIENT_SECRET`
- `TX_PORTAL_CALLBACK_SCOPE`
- `TX_PORTAL_CALLBACK_BPN_CREDENTIAL_TYPE`
- `TX_PORTAL_CALLBACK_MEMBERSHIP_CREDENTIAL_TYPE`
- `TX_PORTAL_CALLBACK_INTERVAL_SECONDS`

The callback client uses OAuth2 client credentials to obtain a Bearer token and
POSTs under `/api/administration/registration/issuer/` with a BPN or Membership
suffix. It requires the Portal service account roles that authorize the two
issuer credential callbacks. The client secret must be supplied with the
separate IdentityHub chart's supported `identityhub.envValueFrom` Secret
reference, not a literal `identityhub.env` value. The IdentityHub chart also
supports `envSecretNames`; prefer a one-key `envValueFrom` reference for the
client secret. Use HTTPS for the callback base and token URL.

## Connector DCP/DIV is a separate endpoint contract

The locked Connector 0.13.0 chart and source distinguish:

- `dcp.sts.div.url` → `TX_EDC_IAM_STS_DIV_URL`. When configured, Connector
  chooses its DIV-specific STS client and POSTs the DCP `grantAccess` or
  `signToken` request to that URL with a Bearer token.
- `dcp.sts.oauth.token_url`, `dcp.sts.oauth.client.id`, and
  `dcp.sts.oauth.client.secret_alias` → OAuth token URL, client ID, and secret
  alias in the Connector's Vault. The Connector obtains the Bearer token from
  this OAuth endpoint.
- `TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL` → the configured credential-service
  base used by the DCP Credential Service client.
- `dcp.trustedIssuers` → trusted issuer DIDs and, optionally, supported
  credential types.

The Connector chart documentation explicitly describes the DIV account as a
wallet holding the required credentials. The EDC source's DIV client sends the
DIV-specific `grantAccess`/`signToken` payloads. IdentityHub chart source
confirms separate Identity, Credential, DID, and STS services, but the reviewed
source does **not** establish that IdentityHub implements the EDC DIV
`grantAccess`/`signToken` API. Therefore this candidate does not point
`dcp.sts.div.url` at IdentityHub's STS or Credential Service URL. That would be
an unsupported endpoint substitution.

IssuerService is the DCP credential issuer, not automatically the Connector's
DIV endpoint. Portal registers the holder with IssuerService's internal admin
API, then the holder requests BPN/Membership credentials through IdentityHub;
the callback extension notifies Portal when those requests reach a terminal
state. Connector issuer trust and consumer/provider wallet/DIV configuration
must use the existing published issuer DID and approved credential types.

## Provisioner review (dirty source checkout; not copied)

The dirty Umbrella checkout contains an offline controller and a separate
chart/CRD. Its documented boundary is a dedicated `be293-connectors` namespace,
with namespaced RBAC, a namespaced `EdcTenantConnector` CRD, externally
provisioned read-only identity/DB, Portal, and Vault credentials, and tenant
Connector releases. The README says the Portal side is designed but not
implemented and the controller has not been deployed or exercised against live
systems. The source is not included here because the checkout is dirty and its
remaining decisions are unresolved.

Before packaging/integration, owners must review: the namespace and RBAC scope
(the current untracked chart contains broad namespace-local create/update/delete
verbs for Secrets, workloads, PVCs, and NetworkPolicies); image build and
immutable digest publication; Portal service-account OAuth permissions and
callback; Vault token role/lifecycle and tenant alias ownership; read-only DB
credentials and allowable identity facts; per-tenant egress/DSP exposure; and
failure/deprovision semantics. Do not enable the controller until the chart,
image, CRD compatibility, security review, and tenant lifecycle are approved.

## Remaining decision gates

1. Identity owner supplies the existing IdentityHub/IssuerService release
   names, namespace, configured service ports, canonical participant/issuer
   DIDs and context IDs, credential definition IDs, and BPN/Membership type
   strings.
2. Security owner provisions the two Portal API-key Secret references and the
   IdentityHub callback-client Secret reference, plus the narrowly scoped
   callback service-account role. No payload belongs in this repository.
3. Identity/EDC owners demonstrate a supported DIV implementation compatible
   with Connector 0.13.0, or supply an approved alternative DCP flow. Do not
   substitute the IdentityHub STS endpoint by assumption.
4. Build and deploy exact Portal Backend and IdentityHub artifacts, apply the
   Portal database migration in a rehearsed environment, and validate callback
   and credential delivery end-to-end before claiming functional integration.
