# BE293 Alpha EDC E2E (Bruno)

End-to-end DCP data exchange between the two hand-deployed test connectors in `be293`:
provider `be293-edc-fv1` (BPNL000000000FV1) → consumer `be293-edc-guc` (BPNL000000000GUC).
Same layout as the DEV collection `docs/common/api/bruno/Umbrella-bru/` (bruno.json, collection.bru,
environments, numbered folders, `{{Var}}` URLs, `X-Api-Key` header).

The provider bodies and the catalog request are generated verbatim from
`../../edc-e2e-provider-objects.alpha.json` (keys `asset`, `accessPolicy`, `contractPolicyV2`,
`contractDefinitionV2`, `consumerCatalogRequest`); `tests/test_bruno_collection.rb` fails if they drift apart.
The v1 contract objects in that file are rollback-only and are not used here.

## Before a run: three port-forwards (loopback only)

```sh
source ~/alpha/env.sh  # once per shell: provides K(); in the repository: source alpha/env.sh
K -n be293 port-forward --address 127.0.0.1 svc/be293-edc-fv1-controlplane 18181:8081 &   # {{Provider}}  management API
K -n be293 port-forward --address 127.0.0.1 svc/be293-edc-guc-controlplane 18182:8081 &   # {{Consumer}}  management API
K -n be293 port-forward --address 127.0.0.1 svc/be293-edc-fv1-dataplane    18183:8081 &   # {{DataPlane}} public API
```

`{{DataPlane}}` is the **provider's** data plane (`be293-edc-fv1-dataplane`), not the consumer's: the EDR endpoint
points at the provider. The EDR's `endpoint` is the in-cluster host name; request 07 reuses only its token.

## API keys (never stored in the collection)

Environment `environments/Alpha env.bru` lists `Provider_Api_Key` and `Consumer_Api_Key` under `vars:secret`.
Fill them in Bruno (they stay local, outside Git) from:

| Variable | Secret | Key |
|---|---|---|
| `Provider_Api_Key` | `be293-edc-fv1-auth` | `management-api-key` |
| `Consumer_Api_Key` | `be293-edc-guc-auth` | `management-api-key` |

## Run order

1. **01-Provider** (once): asset, access policy, contract policy V2, contract definition V2. Each returns 200 with an
   IdResponse; a re-run returns **409** (already present), which the tests accept.
2. **02-Consumer**, in order:
   - 01 catalog → captures `offerId`
   - 02 negotiation → `negotiationId`; the policy echoes the catalog offer (UsagePurpose as the plain string
     `cx.core.industrycore:1`, the form the catalog returns)
   - 03 poll negotiation → waits up to 120 s for FINALIZED, captures `agreementId`
   - 04 transfer (`HttpData-PULL`) → `transferId`
   - 05 poll transfer → waits for STARTED
   - 06 EDR data address → `edrEndpoint`, `edrToken`
   - 07 fetch → **acceptance**: exactly 140 bytes with SHA-256
     `c48268cc16f6e04c1e3500a2d4cd717d656cff95da8abd32dab4f7071f8695c2`
     (`payload.json` of `edc-datasource-be293.alpha.yaml`). The state checks in 03/05 are diagnostics; this is the
     pass criterion.

Negotiation and transfer are asynchronous; 03 and 05 poll in their post-response scripts (`axios`, `crypto-js` are
Bruno built-ins). A TERMINATED negotiation or transfer cannot be resumed: start again from 02 (or 04).

## Follow-up

The management API **v3** logs a deprecation warning in favour of v4. The collection stays on v3 because that is what
was proven end to end on Alpha; move to v4 as a separate, tested change.
