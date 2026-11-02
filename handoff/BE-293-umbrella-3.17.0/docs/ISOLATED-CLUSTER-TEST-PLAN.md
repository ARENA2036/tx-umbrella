# Isolated-Cluster Acceptance Test Plan

**Goal:** prove that this package installs on an **empty** cluster and reaches the revision 21 functional baseline before anyone touches a shared target cluster.

The offline checks (`tools/verify_package.sh`) prove render equivalence only. The items below can be proven only by a real install.

**Status: NOT EXECUTED.** The packaging environment had no container runtime and no registry access.

## 0. What this test must answer

| # | Question | Why it cannot be answered offline |
|---|---|---|
| Q1 | Do all hook Jobs complete within the Helm hook timeout on a cold start? | Hooks start as soon as the manifests are applied. The Portal migration hooks have no database wait and rely on Job retries. |
| Q2 | Does Keycloak realm seeding succeed when the revision 7 **and** revision 13 Jobs run concurrently on an empty realm? | Revision 7 failed on DEV, and the two have never run together on an empty Keycloak (B-04). |
| Q3 | Does the IdentityHub seed hook create 5 participant contexts and reach 16 `ISSUED` credentials against a freshly bootstrapped Vault? | Depends on the Vault policy text (B-03) and on the seed hook's `backoffLimit: 2`. |
| Q4 | Does `did:web` resolution work end to end with the test cluster's DNS and TLS? | Needs real DNS and certificates. |
| Q5 | Does EDC Provider → Consumer 1 **and** Consumer 2 complete DCP catalog, negotiation, transfer and payload checks? | Functional; Consumer 2 has never passed. |
| Q6 | Is a second `helm upgrade` (same values, with hooks) safe? | Post-upgrade hooks re-run seeding (B-04) |

## 1. Environment

- A disposable cluster (kind, k3d or a cloud sandbox) with at least 8 vCPU and 24 GiB RAM, a default StorageClass, ingress-nginx (class `nginx`) and cert-manager. It must have **no network path** to the DEV or target clusters.
- **DNS and TLS for `did:web`.** DIDs are resolved over HTTPS by IdentityHub, IssuerService and EDC, from **inside** the cluster. Use one of:
  - **(a, preferred)** A real test subdomain with an ACME DNS-01 ClusterIssuer named `letsencrypt-dev` and ExternalDNS. Certificates are publicly trusted, so nothing changes in the chart.
  - **(b)** A private CA ClusterIssuer named `letsencrypt-dev`, plus CoreDNS rewrites of `*.be293.dev.<suffix>` to the ingress controller. Every Java and Python workload must then trust the CA. **That is a values change and is not covered by this package**, so record any deviation as a test-only deviation.
- **Registry.** A private test registry holding all images from `inventory/IMAGE-INVENTORY.yaml`, copied by digest, for example with `crane cp <src>@<digest> <dst>@<digest>`. Then set `BE293_REGISTRY_HOST` and `BE293_IMAGE_REPOSITORY` accordingly.
- **Secrets.** Freshly generated, synthetic but strong values. Never DEV values.

## 2. Procedure

Record the time, the command and the result (PASS/FAIL) for every step. Never print credential values.

1. `bash tools/verify_package.sh` reports `ALL CHECKS PASSED`.
2. Run `kubectl create namespace be293`, then create every pre-provisioned Secret (`docs/SECRETS.md` §A) **except** the Vault tokens.
3. Run `helm install be293-vault charts/umbrella-infrastructure -n be293 -f values/values-be293-vault.example.yaml` (adapt storage). Then initialize and unseal Vault, enable KV-v2 `secret/`, and create role `be293-runtime` and the 6 policies (`docs/VAULT-CONTRACT.md`). Mint the 6 tokens and create the token Secrets. Check: each token's `lookup-self` shows `period=24h` and `renewable=true`, and `sys/capabilities-self` matches the contract.
4. Build the overlays (README § Configuration). Run `check_placeholders.rb`, which must report 0. Run `compare_inventory.rb`, which must report 0 differences (or the 6 from the SecretRef overlay). Run `helm install … --dry-run=server`.
5. Install with explicit waits and a generous hook timeout:

   ```bash
   helm install be293-app chart/umbrella -n be293 -f <env>.private.yaml -f <env>.secrets.yaml \
     [-f values/values-be293-identityhub-superuser-secretref.yaml] --wait --wait-for-jobs --timeout 45m
   ```

   Helm's default timeout of 5 minutes also applies to each hook, which is too short for a cold start. While it runs, watch `kubectl get jobs,pods -n be293 -w`.
   - **Q1 PASS** when every hook Job is `Complete` and the release is `deployed`.
6. Keycloak (Q2). Both realm-seeding Job generations are `Complete` for both IdPs. The realms `CX-Central` and the Shared IDP realms exist. Log in to the admin console with the seeded admin. If the revision 7 Jobs fail, record the error category and repeat on a fresh cluster with only revision 13. That repeat needs an owner decision (B-04).
7. Apply `manifests/*.private.yaml`. Wait for the two certificates `identity-hub-legacy-did-be293-tls` and `issuer-service-legacy-did-be293-tls`.
8. Identity (Q3, Q4):
   - **Participant contexts.** Through the IdentityHub Identity API, 4 participant contexts plus the issuer context are ACTIVE.
   - **DID documents.** 5/5 resolve over public HTTPS: check `id`, the verification methods and the service entries.
   - **Credentials.** IssuerService reports 16 `ISSUED` credentials, stable over two CredentialWatchdog cycles. `GET https://issuer-service.<host>/statuslist/<id>` returns 200.
   - **BDRS.** It returns the 4 BPN→DID mappings.
9. EDC (Q5). Follow the repository's `docs/dev/BE-293-edc-0.13-functional-acceptance.md`:
   1. DSP 2025-1 discovery
   2. catalog filtered to the synthetic asset
   3. `FINALIZED` negotiation
   4. `HttpData-PULL` transfer
   5. EDR fetch
   6. payload SHA-256 equals the fixture

   Run this for Consumer 1 **and** Consumer 2. A first-negotiation miss on a cold BDRS cache is known: retry the transfer, not the negotiation.
10. Portal. A browser login through Central IDP works, and an authenticated `ownCompanyDetails` call returns 2xx. Onboarding a synthetic company reaches the IdentityHub wallet step. The IdentityHub → Portal callback returns 2xx; record whether it returns 401 instead.
11. Upgrade safety (Q6):
    - Run `helm upgrade` with identical values and `--no-hooks`. Expect no change to the participant contexts or credentials.
    - Then, on a **separate** fresh cluster only, run `helm upgrade` with hooks to measure the re-seeding impact on `holderPid` and the credentials.
12. Tear-down. `helm uninstall` both releases, then delete the namespace, which also deletes the PVCs. Confirm no cluster-scoped leftovers: the package renders none.

## 3. Exit criteria

| Result | Meaning |
|---|---|
| **ACCEPTED** | Q1–Q5 PASS, Q6 understood and documented, and no deviation from the package except recorded test-only DNS or TLS items |
| **CONDITIONAL** | Q1–Q4 PASS, but EDC or Portal functional checks fail with a known, documented cause |
| **REJECTED** | Any hook fails without a documented cause, or any credential or identity is regenerated unexpectedly |

Store the evidence (commands, IDs, digests, timings, no values) next to this package in Git.
