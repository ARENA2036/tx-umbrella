# Vault Bootstrap Contract (`be293-vault`)

The Helm chart `charts/umbrella-infrastructure` installs only the Vault server. That means one node, Raft storage, and TLS disabled inside the cluster.

Everything the BE-293 workloads need *inside* Vault was created on DEV by operator tooling that lives only in the source checkout's working tree. That tooling is **not packaged**; see `BLOCKERS.md` B-03. This document records the state the tooling creates, so the platform owner can provision it with approved tooling.

**Sources (read-only review, 2026-11-02):**

- `hack/be293-dev-vault-bootstrap.sh`
- `hack/be293-dev-runtime-bootstrap.py`
- `hack/be293_vault_recover.py`
- `hack/be293_seed_plan.json`

All are in `public-tractus-x-umbrella`, and all are untracked.

**Not verified:** the exact live policy text in DEV Vault. No Vault access was used.

## 1. Server lifecycle

| Item | DEV behaviour | Target requirement |
|---|---|---|
| Initialization | `vault operator init -key-shares=1 -key-threshold=1` | Decide the key shares and threshold. Use more than one share for any shared environment. |
| Root token and unseal key | Stored together in namespace Secret `be293-vault-init` | **Do not reproduce.** Keep them outside the cluster, in the operator secret store. With the DEV pattern, anyone who can read Secrets in `be293` controls Vault. |
| Unseal after restart | Manual or scripted, from that Secret | Define the unseal procedure (manual, or auto-unseal through KMS) |
| Address used by workloads | `http://be293-vault:8200` (in-cluster, no TLS) | Same Service name, unless every overlay reference changes |

## 2. Secrets engine

KV version 2, mounted at `secret/`. Workloads use API path prefix `/v1/secret`, because EDC 0.17-based runtimes append `/data` themselves. DEV root cause 3: a path of `/v1/secret/data` breaks every read.

## 3. Token role

`auth/token/roles/be293-runtime` uses these settings:

```
orphan=true renewable=true token_no_default_policy=true token_period=24h token_explicit_max_ttl=0
```

- Runtime tokens are periodic 24-hour tokens created from this role, one policy per consumer.
- The runtime renews its own token. That needs `auth/token/lookup-self` (read) and `auth/token/renew-self` (update) in **every** runtime policy.
- Without them the token silently expires after 24 hours. This was DEV root cause 1.

## 4. Policies and paths

The capabilities are those required by the source tooling.

| Policy | Paths and capabilities |
|---|---|
| `be293-identityhub-runtime` | `secret/data/<identityhub accounts authKeyAlias>`: create, read, update. The alias is set at `identity-and-trust-bundle.identity-hub-postgres.identityhub.endpoints.accounts.authKeyAlias` in the overlay; see `BLOCKERS.md` S-02. |
| | `secret/data/super-user-apikey`: read (see §6) |
| | `secret/data/<iatp.sts.oauth.client.secret_alias>`: create, read, update. The alias is the value configured at `identity-and-trust-bundle.identity-hub-postgres.identityhub.iatp.sts.oauth.client.secret_alias`, a placeholder in the secrets overlay. On DEV it is derived from the credential, so it is not reproduced here (`BLOCKERS.md` S-07). |
| | `secret/data/operator-bpnl00000003crhk-*`, `secret/data/provider-bpnl00000003ayre-*`, `secret/data/consumer-bpnl00000003azqp-*`, `secret/data/consumer-bpnl00000003avth-*`: create, read, update |
| | `secret/data/bpnl*` (Portal-onboarded participants): create, read, update |
| | `auth/token/lookup-self`: read. `auth/token/renew-self`: update. |
| `be293-issuerservice-runtime` | `secret/data/default`: create, read, update |
| | `secret/data/super-user-apikey`: read |
| | `secret/data/issuer-bpnl00000003crhk-*`: create, read, update |
| | `auth/token/lookup-self`: read. `auth/token/renew-self`: update. |
| `be293-bdrs-runtime` | `secret/data/edc.datasource.didentry.user`, `secret/data/edc.datasource.didentry.password`, `secret/data/bdrs-management-api-key`: create, read, update |
| | `auth/token/lookup-self`, `auth/token/renew-self` (see `BLOCKERS.md` B-08) |
| `be293-dataprovider-connector` | `secret/data/be293/dataprovider/{tokenSignerPrivateKey,tokenSignerPublicKey,tokenEncryptionAesKey,edc-wallet-secret}`: create, read, update. Also lookup-self and renew-self. |
| `be293-dataconsumer-1-connector` | The same set under `secret/data/be293/dataconsumer-1/` |
| `be293-dataconsumer-2-connector` | The same set under `secret/data/be293/dataconsumer-2/` |

**Participant context IDs and Vault folders.** These are preserved exactly from DEV and are also in `values/values-be293-dev.example.yaml`:

| Participant | Context ID | BPN | Vault folder |
|---|---|---|---|
| Operator | `operator-bpnl00000003crhk` | BPNL00000003CRHK | — |
| Provider | `provider-bpnl00000003ayre` | BPNL00000003AYRE | `be293/dataprovider` |
| Consumer 1 | `consumer-bpnl00000003azqp` | BPNL00000003AZQP | `be293/dataconsumer-1` |
| Consumer 2 | `consumer-bpnl00000003avth` | BPNL00000003AVTH | `be293/dataconsumer-2` |
| Issuer | `issuer-bpnl00000003crhk` | BPNL00000003CRHK | — |

## 5. Tokens delivered as Kubernetes Secrets

| Kubernetes Secret | Key | Vault policy |
|---|---|---|
| `be293-identityhub-runtime` | `EDC_VAULT_HASHICORP_TOKEN` | `be293-identityhub-runtime` |
| `be293-issuerservice-runtime` | `EDC_VAULT_HASHICORP_TOKEN` | `be293-issuerservice-runtime` |
| `be293-bdrs-vault-token` | `token` | `be293-bdrs-runtime` |
| `be293-dataprovider-connector-crypto` | `vault-token` | `be293-dataprovider-connector` |
| `be293-dataconsumer-1-connector-crypto` | `vault-token` | `be293-dataconsumer-1-connector` |
| `be293-dataconsumer-2-connector-crypto` | `vault-token` | `be293-dataconsumer-2-connector` |

## 6. Shared super-user key

IdentityHub and IssuerService both store their super-user key under Vault alias `super-user-apikey`. They must therefore use the **same** key; otherwise the service seeded last locks the other one out. See `values/values-be293-identityhub-superuser-secretref.yaml` and `docs/SECRETS.md`.

Which runtime may *write* the alias at first start depends on the live policy text. The source tooling grants only `read` and adds missing stanzas. Confirm the alias exists before first start, or that the policy allows the initial write. This is UNKNOWN: `BLOCKERS.md` B-03.

## 7. Order relative to the Helm releases

1. Install `be293-vault`. Then initialize and unseal it, enable KV-v2 at `secret/`, and create the role and policies (§2–§4).
2. Mint the six runtime tokens and create the Kubernetes Secrets in §5, along with all other Secrets in `docs/SECRETS.md`.
3. Install `be293-app`. Its post-install hooks then write into Vault:
   - BDRS setup writes the BDRS aliases.
   - Provider Vault setup writes connector key material from the `*-connector-crypto` Secrets.
   - The IdentityHub seed creates participant contexts, keys and STS secrets.

   If the tokens or policies are missing, the hooks fail. On DEV, the 2026-10-16 IdentityHub seed hook failed and was recovered manually.
