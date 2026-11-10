# BE-293 IssuerService and Portal checks (Bruno)

Diagnoses the BPN credential failure: the IssuerService (`release26-09`) crashes in
`AttestationPipelineImpl.evaluate` (NullPointerException) when holder `BPNL00000000052O` requests the BPN credential.

## Issuer (read-only)
1. Tunnel to the in-cluster admin API (leave it running):
   `kubectl --kubeconfig ~/.kube/alpha.yaml --context alpha -n release26-09 port-forward svc/issuer-service 18086:8086`
2. In Bruno: Open Collection -> this folder; select the environment `alpha-port-forward`.
3. Set the secret `issuerAdminApiKey` (stored locally by Bruno, never in these files). It is sent only by the
   requests in this folder, never to the Portal.
4. Run 01-06. GET and `POST .../query` only; do not add create/update/delete requests.

## Portal (operator login)
1. Collection settings -> Auth (OAuth 2.0, authorization code + PKCE, realm CX-Central, client `Cl2-CX-Portal`)
   -> "Get Access Token". Bruno opens the Keycloak login; log in as the operator (role `approve_new_partner`).
2. Run 10 (read-only checklist) for `applicationId`.
3. 11/12 retrigger a credential and CHANGE the application: send only after approval and after the issuer fix.
   They refuse to send unless `confirmRetrigger` equals `applicationId`, and clear it afterwards.

If Keycloak rejects the redirect URI, set `portalCallbackUrl` to a redirect URI registered for `Cl2-CX-Portal`.
Before sharing responses, remove anything that looks like a key or token.
