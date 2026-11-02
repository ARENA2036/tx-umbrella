# BE-293 DEV values handoff (be293-app)

Status: **BLOCKED. Do not deploy this branch to DEV.**
Prepared 2026-10-30 from read-only checks. No cluster changes were made.

## Summary

The release `be293-app` (namespace `be293`, context `k8s-dev-01`) runs
`umbrella-3.17.0`, revision 21. This branch's chart is `umbrella-3.14.1`. The
two charts are different products, not neighbouring versions. You cannot build a
`values-be293-dev.yaml` overlay that keeps the current DEV topology on 3.14.1.
For that reason no overlay file was created.

## Where 3.17.0 comes from

- No git ref in `tx-umbrella`, `tx-umbrella-0.13`, `tx-umbrella-013-acceptance`,
  `tx-umbrella-dtr-tls` or this worktree contains `version: 3.17.0`. The highest
  version in git is `3.16.0` (upstream `origin/release-26-03`). It does not
  have the BE-293 DEV components either.
- The packaged 3.17.0 chart exists only in the Helm release record
  (`sh.helm.release.v1.be293-app.v21`). All of revisions 12–21 use it.
- In short, 3.17.0 is an unversioned local build. Its source is not under
  version control.

| Dependency | DEV 3.17.0 | This branch 3.14.1 |
|---|---|---|
| bdrs-server | 0.6.0 (Postgres and Vault backed) | not present (`bdrs-server-memory` 0.5.7 instead) |
| identity-and-trust-bundle | 1.2.0 (IdentityHub, IssuerService, Postgres) | 1.1.2 (`ssi-dim-wallet-stub` only) |
| tx-data-provider (x3) | 0.5.0 (`wallet.mode`, `identityHubSeed`, `vaultSetup.crypto`) | 0.4.3 (Connector 0.13 SecretRefs, different `vaultSetup`) |
| selfdescription | 2.1.35 | 2.1.34 |
| ssi-credential-issuer, semantic-hub, pgadmin4, observability, cert-manager | not in chart | present |
| Umbrella templates | wallet derive/validate, didweb-resolver, bdrs provision and NetworkPolicy, CoreDNS patch | onboarding-process-worker |

## What a 3.14.1 upgrade would do to DEV

This comes from an offline render of 3.14.1 with the DEV values, after secrets
were replaced with placeholders. It was compared against the live revision 21
manifest by kind and name only.

- **Removes 55 resources**, including:
  - `Deployment/bdrs-server` and `StatefulSet/bdrs-postgresql` (BPN→DID directory)
  - `Deployment/be293-app-identity-hub-postgres` and `StatefulSet/be293-app-identityhub-postgresql`
  - `Deployment/be293-app-issuer-service` and `StatefulSet/be293-app-issuer-postgresql`
  - `Deployment/didweb-resolver` and `StatefulSet/submodel-postgresql`
  - the IdentityHub seed Job and RBAC
- **Removes Portal IdentityHub wiring.** All `APPLICATIONCHECKLIST__IDENTITYHUB__*`
  settings, `ONBOARDING__WALLETPROVIDER` and `CONNECTORPROVISIONING__*` disappear.
  Legacy `*__USEDIMWALLET` flags come back.
  - The Portal patch on this branch uses different keys (`portal.backend.identityHub.*`).
  - It requires `https://` endpoints. DEV uses internal `http://` Service URLs.
- **Fails to render** until new Connector SecretRefs exist (see below).
- **Re-runs Keycloak realm seeding** as Jobs `*-realm-seeding-1`. DEV keeps
  revisions 7 and 13 through the 3.17.0-only `recovery*` keys.
- The submodel server image falls back from a digest to `be293-images:0.0.1`.
- The SD factory image changes from `2.1.26` to `2.1.25`.

Identities that must be preserved (all are in the DEV values today):

| Role | Identity |
|---|---|
| Operator / issuer | BPNL00000003CRHK, issuer DID `did:web:issuer-service.be293.dev.construct-x.net:BPNL00000003CRHK` |
| Provider | BPNL00000003AYRE |
| Consumer 1 | BPNL00000003AZQP |
| Consumer 2 | BPNL00000003AVTH |

- Participant DIDs have the form `did:web:identity-hub.be293.dev.construct-x.net:<BPN>`.
- BDRS is seeded with all four BPN→DID mappings.

## Secret references

- All 15 Secrets named in the DEV values **exist** in `be293`, with the expected
  key names. Only names were checked, no payloads.
- 3.14.1 additionally **requires these, and they are missing** for each of
  `tx-data-provider`, `dataconsumerOne` and `dataconsumerTwo`:
  - `...tractusx-connector.controlplane.endpoints.management.authKeySecretRef.{name,key}`
  - `...tractusx-connector.dataplane.endpoints.proxy.authKeySecretRef.{name,key}`
  - `...tractusx-connector.postgresql.auth.passwordSecretRef.{name,key}`
  - `...tractusx-connector.vault.hashicorp.tokenSecretRef.{name,key}`. Candidate:
    `be293-<participant>-connector-crypto` / `vault-token`.
  - `vaultSetup.tokenSecretRef`, `vaultSetup.keyMaterialSecretRef` and
    `vaultSetup.seedPayloadSecretRefs.edc-wallet-secret`. There is no matching
    seed-payload Secret today.
  - Today DEV passes the management key, the proxy key and the DB password to
    the EDC pods as **inline env values** (chart defaults). The right Secret
    contents must come from the owner. Do not copy them from the pods.

### Security finding

The DEV release values contain **8 plaintext credentials**. Helm stores them in
every release revision Secret:

- `identity-and-trust-bundle.identity-hub-postgres.identityhub.env.EDC_IH_API_SUPERUSER_KEY`
- `identity-and-trust-bundle.identity-hub-postgres.identityhub.iatp.sts.oauth.client.secret`
- `identity-and-trust-bundle.identity-hub-postgres.identityhub.iatp.sts.oauth.client.x_api_key`
- `identity-and-trust-bundle.issuer-service.issuerservice.env.EDC_IH_API_SUPERUSER_KEY`
- `portal.backend.processesworker.identityHub.apiKey`
- `portal.backend.processesworker.identityHub.issuerAdminApiKey`
- `portal.backend.processesworker.bpnDidResolver.apiKey`
- `bdrs-server-memory.server.endpoints.management.authKey`. This component is
  disabled.

Never commit `/Users/payam/be293-dev-values.yaml` or any copy of it.

## Safe next steps for deployment

1. **Do not run** `helm upgrade be293-app ./charts/umbrella ...` from this branch.
2. Pick a direction. This needs an owner decision:
   - **A. Keep DEV on 3.17.0.** Recover the 3.17.0 chart source, review it, and
     commit it to a dedicated branch. Then derive a secret-free overlay from it.
   - **B. Port the DEV topology into this branch first.** That means:
     - `bdrs-server` 0.6.0 and identity-and-trust-bundle 1.2.0
     - tx-data-provider 0.5.0 wallet modes
     - the Umbrella wallet and didweb templates
     - a Portal `processesworker.identityHub` mapping that accepts SecretRefs and
       internal http
     - the Connector SecretRefs above

     Then build the overlay and repeat the checks below.
3. Read-only checks you can repeat (they change nothing):

   ```bash
   export KUBECONFIG=~/.kube/stackit-dev.yaml
   helm --kube-context k8s-dev-01 -n be293 history be293-app --max 10
   helm --kube-context k8s-dev-01 -n be293 get metadata be293-app -o json   # chart + dependency versions
   helm lint charts/umbrella -f <sanitized-values>
   helm template be293-app charts/umbrella -n be293 -f <sanitized-values> -f <synthetic-secretrefs>
   ```

   Render only with sanitized values (placeholders instead of credentials). Never
   pass `--debug`, and never print or commit rendered output that contains real
   values.
