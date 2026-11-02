# Deployment Checklist: BE-293 Umbrella 3.17.0 (revision 21 baseline)

No step here has been executed against any cluster. Each install step needs approval from the target environment owner.

## A. Decisions and inputs (BLOCKERS.md)

- [ ] A1. Platform Team confirms the target platform (B-01): namespace `be293`, default StorageClass, ingress-nginx (`nginx`, regex), cert-manager ClusterIssuer, ExternalDNS, DNS suffix, hostname pattern.
- [ ] A2. Identity Owner decides fresh identities versus restoring DEV identities (B-05).
- [ ] A3. Identity Owner and Integration Team decide the realm-seeding generations on an empty cluster (B-04).
- [ ] A4. Integration Team confirms the excluded components stay excluded (B-10).
- [ ] A5. Security Team decides whether to use `values-be293-identityhub-superuser-secretref.yaml` (recommended; S-01) and whether to override the EDC proxy key (S-03).

## B. Artifacts

- [ ] B1. `bash tools/verify_package.sh` prints `ALL CHECKS PASSED`.
- [ ] B2. Mirror every image in `inventory/IMAGE-INVENTORY.yaml` **by digest** into the approved registry, and record the new references (B-02).
- [ ] B3. Create the environment overlay and the manifests with `tools/apply_environment.rb` (README § Configuration).
- [ ] B4. Fill the secrets overlay from the approved secret store. Keep every list entry, and keep the matching OAuth pairs equal (`docs/SECRETS.md` §B).
- [ ] B5. Run `helm template … | ruby tools/check_placeholders.rb`, which must report `placeholders=0 example-identifiers=0`.
- [ ] B6. Run `helm template … | ruby tools/render_inventory.rb --normalize-registry > /tmp/x.json; ruby tools/compare_inventory.rb inventory/expected-rev21-inventory.json /tmp/x.json`. Expect 0 differences, or exactly the 6 from the SecretRef overlay. Explain any other difference before going on.

- [ ] B7. Run `docs/ISOLATED-CLUSTER-TEST-PLAN.md` on a disposable cluster and reach ACCEPTED or CONDITIONAL (B-11). Do not touch a shared cluster before this.

## C. Platform and Vault (target, after approval)

- [ ] C1. Create namespace `be293`.
- [ ] C2. `helm install be293-vault charts/umbrella-infrastructure -n be293 -f values/values-be293-vault.example.yaml` (adapt storage).
- [ ] C3. Initialize and unseal Vault. Keep the root and unseal material **outside** the cluster (S-04).
- [ ] C4. Enable KV-v2 at `secret/`, and create role `be293-runtime` and the 6 policies (`docs/VAULT-CONTRACT.md` §2–§4, including `lookup-self` and `renew-self`).
- [ ] C5. Mint 6 periodic runtime tokens. Verify their capabilities without printing them.

## D. Secrets and release

- [ ] D1. Create every pre-provisioned Secret (`docs/SECRETS.md` §A), and `identityhub-superuser` if A5 is accepted. Check key names only.
- [ ] D2. Run `helm install be293-app chart/umbrella -n be293 -f <env>.private.yaml -f <env>.secrets.yaml [-f values/values-be293-identityhub-superuser-secretref.yaml] --dry-run=server`.
- [ ] D3. Run `helm install` with the same arguments, watching the hooks in this order: Portal migrations, provisioning migrations, BDRS setup, IdentityHub seed, test data. Stop on the first failed hook. Do **not** re-run non-idempotent seeding blindly (B-04).
- [ ] D4. Run `kubectl apply -f manifests/*.private.yaml` (4 Ingresses), and wait for cert-manager to issue `identity-hub-legacy-did-be293-tls` and `issuer-service-legacy-did-be293-tls`.

## E. Functional acceptance

Status labels:

- **PASS**: verified with evidence.
- **NOT VERIFIED**: not run.

Do not infer success from `Running`/`Ready`.

- [ ] E1. Vault is unsealed. Every runtime token is valid and renewable, and has the required capabilities.
- [ ] E2. IdentityHub: 4 participant contexts plus the issuer context are ACTIVE.
- [ ] E3. Each of the 5 DIDs resolves over public HTTPS. Check that the document `id` and verification methods are valid.
- [ ] E4. IssuerService: 16 credentials are `ISSUED` (4 participants × Membership, BPN, DataExchangeGovernance, FrameworkAgreement), stable across two CredentialWatchdog cycles, with the StatusList reachable at `https://issuer-service.<host>/statuslist/…`.
- [ ] E5. BDRS returns the 4 BPN→DID mappings.
- [ ] E6. EDC Provider → Consumer 1:
  1. DSP 2025-1 discovery
  2. catalog contains the synthetic asset
  3. negotiation reaches `FINALIZED`
  4. transfer `HttpData-PULL`
  5. EDR fetch
  6. payload SHA-256 equals the fixture

  Expect a retry after a cold BDRS cache: DEV follow-up 1.
- [ ] E7. EDC Provider → Consumer 2: same as E6. Never accepted on DEV.
- [ ] E8. Portal: browser login through Central IDP, and an authenticated `ownCompanyDetails` call returns 2xx. Onboarding a test company reaches the IdentityHub wallet step. Check that the IdentityHub → Portal callback returns 2xx, not 401.
- [ ] E9. BPDM gate, pool and orchestrator are reachable with a token. Discovery Finder and BPN Discovery answer.
- [ ] E10. Record the evidence (commands, IDs, digests, no secrets) in Git.

## F. Rollback and recovery notes

- **Before go-live:** an uninstall leaves the PVCs in place, because they come from StatefulSet templates. Deleting the namespace deletes the data.
- **Never delete or reseed after credentials are issued.** DIDs, keys and STS secrets are linked across Vault, the IdentityHub database and the connectors.
- **Database migrations are not reversed by `helm rollback`.** Use backup and restore.
