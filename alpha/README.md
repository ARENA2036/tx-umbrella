# alpha/ — BE-293 Alpha (cluster `alpha`, namespace `be293`)

`source alpha/env.sh` first (bash or zsh): it sets `$ROOT $UMB $ALPHA $REL $IDENT $CHARTS $HELM_PLUGINS $KUBECONFIG` and `K()`.

| Folder | What it is |
|---|---|
| `portal/` (`$REL`) | Portal release package: values, tools, post-renderers (`helm-plugins/`), gates, tests, Bruno, docs (`docs/BE293-FOLDER-GUIDE.md`) |
| `identity/` (`$IDENT`) | Own identity stack (Vault, PostgreSQL, IssuerService, IdentityHub, BDRS) and the two EDC E2E test connectors: values, tools, gates, tests, Bruno (`bruno/BE293-Alpha-EDC-E2E/`) |
| `charts/` (`$CHARTS`) | Vendored charts: `portal-2.6.0-patched/`, `centralidp-4.2.1-patched/`, `sharedidp-4.2.1-patched/`, `identity/` (identity + connector charts, `patches/`; pinned in `identity/charts.lock.yaml`) |

Package commands (`bash tools/…`, `ruby tests/…`) run from inside their package: `cd "$REL"` or `cd "$IDENT"`.
