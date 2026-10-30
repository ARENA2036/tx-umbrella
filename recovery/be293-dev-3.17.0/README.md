# BE-293 Umbrella 3.17.0 baseline (sanitized)

**Status: REFERENCE BASELINE. This is not deployable as committed.**

This directory contains the Umbrella 3.17.0 Helm chart and the DEV overlay
structure that BE-293 runs. It covers IdentityHub, IssuerService, BDRS, three
EDC connectors, Portal, Central/Shared IDP, BPDM and the discovery services.

Everything here is sanitized:

- Credentials are replaced with `<<SET-FROM-SECRET-STORE:...>>` placeholders.
- Environment identifiers are replaced with reserved example values that can
  never resolve (RFC 6761):

  | Identifier | Example value |
  |---|---|
  | DNS suffix | `example.invalid` |
  | Registry host | `registry.example.invalid` |
  | Image repository | `registry.example.invalid/be293/be293-images` |

A render with these files is structurally complete but cannot run against a
real environment.

The chart was recovered from a deployed Helm release. These files are not the
original development sources: the chart was reassembled from the release record
and the matching dependency packages. See `VALIDATION.md` for how faithful the
recovery is.

## Layout

| Path | Content |
|---|---|
| `chart/umbrella/` | Helm chart: `Chart.yaml`, `Chart.lock`, `templates/`, `files/`, `values.yaml` (credential defaults are placeholders) |
| `chart/umbrella/charts/*.tgz` | 22 dependency packages. See `VALIDATION.md` for provenance and the one rebuilt package. |
| `values/values-be293-dev.example.yaml` | DEV overlay with example identifiers and credential placeholders |
| `values/values-be293-dev.secrets.example.yaml` | Template listing every credential placeholder that matters for this overlay |
| `tools/` | Offline helpers. They never print secret values. |

## How to supply real values securely

You need two private files, created locally and never committed. The
`.gitignore` in this directory ignores `*.private.yaml` and `*.secrets.yaml`.

### 1. Environment overlay

Generate it from the example overlay. Ask the platform owner for the three
values, and do not put them in shell history files or tickets:

```bash
cd recovery/be293-dev-3.17.0
BE293_DNS_SUFFIX='<dns suffix>' \
BE293_REGISTRY_HOST='<registry host>' \
BE293_IMAGE_REPOSITORY='<registry host>/<namespace>/<repository>' \
ruby tools/apply_environment.rb values/values-be293-dev.example.yaml values/be293-dev.private.yaml
```

The tool:
- writes the file with mode 600
- refuses output names that are not `*.private.yaml`
- fails if any example identifier remains

### 2. Secrets overlay

1. Copy `values/values-be293-dev.secrets.example.yaml` to
   `values/be293-dev.secrets.yaml`.
2. Replace every `<<SET-FROM-SECRET-STORE:...>>` placeholder with the value
   from the approved secret store.
3. Keep every list entry (Helm replaces lists instead of merging them).
4. Restrict the file to your user (`chmod 600`) and delete it when you no
   longer need it.

Use Kubernetes Secret references wherever the chart supports them, instead of
inline values.

### Values order (last file wins)

```bash
helm template be293-app recovery/be293-dev-3.17.0/chart/umbrella -n be293 \
  -f recovery/be293-dev-3.17.0/values/be293-dev.private.yaml \
  -f recovery/be293-dev-3.17.0/values/be293-dev.secrets.yaml
```

The chart's own `values.yaml` is applied first, automatically.

For an offline check without real values, use the two example files instead.
The placeholders then render as literal strings:

```bash
helm lint recovery/be293-dev-3.17.0/chart/umbrella \
  -f recovery/be293-dev-3.17.0/values/values-be293-dev.example.yaml \
  -f recovery/be293-dev-3.17.0/values/values-be293-dev.secrets.example.yaml
```

Never use `--debug`, and never share or commit output rendered with real
values.

## Kubernetes Secrets the overlay references (pre-provisioned, not created by the chart)

| Purpose | Secret | Keys |
|---|---|---|
| Image pull | `be293-dockerhub-pull` | `.dockerconfigjson` |
| Keycloak TLS CA | `be293-app-centralidp-crt`, `be293-app-sharedidp-crt` | `ca.crt` |
| BDRS | `be293-bdrs-database` | `username`, `password` |
| BDRS | `be293-bdrs-postgres-admin` | `postgres-password` |
| BDRS | `be293-bdrs-management` | `api-key` |
| BDRS | `be293-bdrs-vault-token` | `token` |
| Connectors | `be293-dataprovider-connector-crypto`, `be293-dataconsumer-1-connector-crypto`, `be293-dataconsumer-2-connector-crypto` | `vault-token` |
| IdentityHub, IssuerService | `be293-identityhub-postgres`, `be293-issuerservice-postgres` | `postgres-password` |
| IdentityHub, IssuerService | `be293-identityhub-runtime`, `be293-issuerservice-runtime` | runtime environment keys |
| Submodel server | `be293-submodel-database` | `username`, `password`, `postgres-password` |

Secret contents come from the secret owner. They are never stored in this
repository.

## Guardrails kept from the DEV deployment

With `be293.deploymentProfile: k8s-dev-01`, the chart refuses to render unless
the platform contract holds:
- namespace `be293`
- cert-manager TLS
- pre-provisioned Secrets
- no embedded Vault
- digest-pinned private images from `be293.privateImages.approvedRepository`

The approved repository used to be a hard-coded literal. It is now a value that
the platform owner supplies.

## Limitations

- Credentials and environment identifiers must be supplied as described above.
- Some dependency charts use Helm `lookup` against live cluster objects.
  Offline renders cannot reproduce those objects exactly.
- State outside Helm is not part of this baseline: Vault contents, databases,
  Keycloak realms, IdentityHub participant contexts, DID documents and
  credentials.
- Container images are referenced by digest from a private registry. Their
  build sources are not part of this baseline.
- Deploying, upgrading or rolling back a shared environment from these files
  requires approval from that environment's owner.
