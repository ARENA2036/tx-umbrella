# BE-293 EDC 0.13 Functional Acceptance

This is a test plan and offline contract-test companion for the local EDC 0.13
migration checkpoint. It does not call an API or contain credentials. The
existing Bruno examples are useful historical illustrations, but their
environment variables and routes must not be copied into the 0.13 DEV test
without checking the deployed chart's actual management and dataplane routes.

## Preconditions and identity checks

Record only identifiers, boolean checks, and sanitized status categories. Never
print an API key, Vault token, VC/JWT, EDR `authorization` value, or complete
EDR response.

1. Confirm the running Control Plane and Data Plane image tags/digests are the
   intended 0.13 build. Confirm their configured participant DID, BPN and
   `contextId` match the approved profile; do not generate a replacement ID.
2. For Provider and Consumer 1, confirm the IdentityHub ParticipantContext is
   ACTIVE and the exact DID resolves over HTTPS. Check DID document `id`, the
   verification method used by the connector, and the `DataService` entry used
   for connector discovery. Confirm the document is PUBLISHED, not merely that
   the HTTP route exists.
3. Confirm the issuer DID is in the connector's DCP trusted-issuer configuration
   and that its DIV/credential-service endpoints resolve and validate TLS.
4. Determine the credential requirements from the Provider's actual catalog
   access policy and usage policy. Check Wallet inventory metadata for the
   required credential types, expected holder DID/BPN, trusted issuer, active
   validity/status and expiry. Where the configured default catalog scope is
   used, the Connector documentation describes Membership, BPN and Data
   Exchange Governance credentials. Inventory metadata is only a precheck:
   the live DCP presentation/signature, issuer trust and policy evaluation must
   succeed in the real connector-to-connector exchange.
5. Confirm Provider already has one approved synthetic asset, an access policy
   and a contract definition exposing it to the test Consumer. Confirm the
   catalog advertises `HttpData-PULL` and its source serves a fixed synthetic
   byte fixture. If this is absent, stop; creation is a separate mutating
   authorization.
6. Supply existing Consumer 1 and Provider management credentials through the
   approved protected runtime input only. Use the configured management base
   URLs, HTTPS, certificate verification, bounded timeouts, and in-memory
   headers. Do not put credentials in shell arguments, files, CI variables,
   Bruno exports, logs or test output.

## Acceptance sequence

All paths below are relative to the deployed Connector management API base.
For the documented v3 API, the base is commonly `/api/management`; derive the
actual base and route from the exact 0.13 chart/runtime before execution.

### 1. Discover Provider DSP parameters

Prefer Consumer 1's `POST /v3/connectordiscovery/connectors` with the Provider
DID. It resolves the DID document and discovers its advertised DSP version. If
the Provider's DID/service metadata has already been independently verified,
`POST /v3/connectordiscovery/dspversionparams` can be used with the DID and
known base DSP endpoint. For DSP 2025-1, the resulting address normally ends
`/api/v1/dsp/2025-1` and the protocol is
`dataspace-protocol-http:2025-1`. Do not append a version suffix to a URL that
already contains one. Stop if discovery returns no supported common version,
or its DID/address does not match the approved Provider identity.

### 2. Catalog Request (Consumer 1, read-only application operation)

`POST /v3/catalog/request` on Consumer 1's management API. Use a
`CatalogRequest` with `counterPartyId` set to the Provider DID for DSP 2025-1,
the discovered `counterPartyAddress` and `protocol`. Add a `querySpec` filter
for the approved synthetic asset ID to keep the response bounded. A successful
HTTP response alone is not acceptance: require the expected dataset ID, one
selected Offer whose policy can be parsed, an advertised distribution, and the
expected Provider DSP endpoint. An empty catalog is a functional failure and
can mean the Provider's access policy did not admit the Consumer's presented
DCP credentials; it is not evidence that the catalog API is healthy enough.

### 3. Contract Negotiation (state-changing)

`POST /v3/contractnegotiations` on Consumer 1's management API using a
`ContractRequest`. Select an Offer from the catalog and copy its `@id`,
`permission`, `prohibition` and `obligation` clauses exactly. Bind `assigner`
to the Provider identifier returned/verified for that catalog and `target` to
the selected dataset ID. Use the same discovered DSP address and protocol.
Omit callbacks unless an approved callback listener exists. Record only the
returned negotiation ID. Poll
`GET /v3/contractnegotiations/{negotiationId}` with bounded intervals. Pass
only when the state is `FINALIZED` and an agreement ID is available; stop on
`TERMINATED`, a rejected/terminal state, or timeout, and report only sanitized
error categories. The offline helper rejects transfer preparation unless the
polled state is exactly `FINALIZED` and its agreement ID is present.

### 4. Data Transfer (state-changing)

`POST /v3/transferprocesses` on Consumer 1's management API with the finalized
agreement ID, same Provider DSP address/protocol, and a `transferType` actually
advertised by the selected distribution. For the approved HTTP pull fixture,
use `HttpData-PULL` and `dataDestination: {"type":"HttpProxy"}`. Record only
the transfer-process ID. Poll
`GET /v3/transferprocesses/{transferProcessId}`. For HTTP pull, `STARTED` means
the EDR was issued/cached; it does **not** prove data bytes were fetched. A
terminal error or timeout fails the transfer stage.

Retrieve the EDR only inside protected memory. Its authorization and refresh
fields are bearer credentials; never print or persist them. Fetch the fixture
through the configured Consumer proxy when that endpoint is enabled and
confirmed by the 0.13 chart, or through the verified EDR endpoint using the
approved protected client. Pass only when received bytes exactly match the
known synthetic fixture bytes (or an independently fixed expected SHA-256).
Do not treat negotiation, transfer `STARTED`, EDR presence, or HTTP 2xx as
payload verification.

## Expected failures and triage

| Observation | Interpretation / action |
|---|---|
| Management `401`/`403` | Management auth or authorization failure; do not retry with another credential. |
| Discovery/DSP `404` or no common version | Wrong endpoint, DID service metadata, or unsupported protocol; verify discovered data before changing config. |
| Catalog `2xx` with no matching dataset/offer | No eligible published contract definition, or the Provider access policy did not accept the Consumer's DCP presentation. |
| Catalog `400`/`422` | Request JSON-LD, DID/BPN identity form, address, or protocol mismatch. |
| Negotiation terminal failure | Offer policy mismatch, credential/policy validation, issuer trust, or DSP exchange failure; preserve sanitized state and stop. |
| Transfer terminal failure | Agreement, transfer type/destination, provider data plane, or data-source failure. |
| HTTP pull transfer remains `STARTED` | Normal after EDR issuance; payload retrieval and byte comparison are still required. |
| Payload HTTP `2xx`, bytes differ | Functional failure; retain only lengths/status/digest comparison outcome, not payload content. |
| TLS/DID/signature failure | Stop; never disable certificate or VC verification. |

Do not automatically repeat non-idempotent negotiation or transfer POSTs after
timeouts. First query by the returned operation ID if one was received, or
inspect approved metadata for whether the server created the operation.

## Offline coverage versus DEV acceptance

| Local/offline (synthetic only) | Requires the DEV cluster and protected credentials |
|---|---|
| Validate CatalogRequest and DSP 2025-1 endpoint pairing | Management API authentication and actual Connector version/routes |
| Select only a catalog dataset with an advertised transfer format | IdentityHub context state and published DID document resolution |
| Preserve the selected Offer policy when constructing ContractRequest | Real DCP presentation, VC signature/issuer trust and provider policy evaluation |
| Reject missing agreement IDs and unsupported transfer modes | Live Catalog, finalized negotiation and transfer state progression |
| Check credential inventory metadata and expected holder/issuer/type/status (not signatures) | EDR issuance, protected data retrieval and actual payload byte comparison |
| Compare synthetic payload bytes/digests | Any fixture creation, asset/policy/contract creation, negotiation or transfer writes |

The new helper and unit tests contain no HTTP client and cannot perform live
acceptance. The existing Bruno collection contains older examples with
environment-supplied endpoints and management keys; it is not a substitute for
the protected 0.13 run procedure. No DEV credentials or fixture payload are
embedded here.

## Relevant Connector references

- [Catalog request and connector discovery](https://github.com/eclipse-tractusx/tractusx-edc/blob/main/docs/usage/management-api-walkthrough/04_catalog.md)
- [Contract negotiation](https://github.com/eclipse-tractusx/tractusx-edc/blob/main/docs/usage/management-api-walkthrough/05_contractnegotiations.md)
- [Transfer processes](https://github.com/eclipse-tractusx/tractusx-edc/blob/main/docs/usage/management-api-walkthrough/06_transferprocesses.md)
- [EDR retrieval and data access](https://github.com/eclipse-tractusx/tractusx-edc/blob/main/docs/usage/management-api-walkthrough/07_edrs.md)
- [0.12 to 0.13 migration guide](https://github.com/eclipse-tractusx/tractusx-edc/blob/main/docs/migration/2026_06-Version_0.12.x_0.13.x.md)
