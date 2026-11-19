# alpha/ — BE-293 Alpha working folder (cluster `alpha`, namespace `be293`)

Everything needed to deploy, upgrade, operate and test be293 on Alpha. It lives in the tx-umbrella repository as
`alpha/` and is exported unchanged to `~/alpha` by `tools/export-standalone.sh` (one layout; never edit `~/alpha` by
hand: change the repository and re-export). In the export no path points outside the folder except the two credential
locations below, which never belong in it.

## 1. FIRST: Vault comes back SEALED after every restart of its pod

The identity Vault (`be293-identity-vault-0`, Raft storage on a PVC) uses manual Shamir unseal. After ANY restart of
that pod (node drain, eviction, rollout, crash) it starts **sealed**. While it is sealed, IssuerService, IdentityHub,
BDRS and both test EDCs cannot read their secrets: issuance, DID resolution and data exchange stop.

Symptom: `be293-identity-vault-0` shows `0/1` Ready. Check and unseal:

```sh
source ~/alpha/env.sh                           # in the repository: source alpha/env.sh
cd "$IDENT"
bash tools/identity-vault-be293.sh --status    # read-only: expect sealed=true after a restart
bash tools/identity-vault-be293.sh --unseal    # type exactly: unseal the be293 identity vault
bash tools/identity-vault-be293.sh --status    # must now show sealed=false
K -n be293 get pods                             # dependants recover; restart only pods stuck in CrashLoopBackOff
```

The tool port-forwards to the Vault pod on 127.0.0.1 itself and applies 3 of the 5 unseal keys.

**Key file:** `~/.be293-vault/vault-init.json` (directory mode 0700, file 0600; written once by `--init`; override the
directory with `BE293_VAULT_DIR`). It holds the unseal keys (and the root token until `--revoke-root`). It is
deliberately outside this folder and outside Git; if you moved the unseal keys to separate safe storage, put the file
back there before `--unseal`. Never print it.

## 2. Start

```sh
source ~/alpha/env.sh      # in the repository: source alpha/env.sh. bash or zsh; sets ROOT ALPHA REL IDENT CHARTS UMB
                           # HELM_PLUGINS KUBECONFIG BE293_LAYOUT (repo|standalone) and K()
```

Package commands run from inside their package (`cd "$REL"` or `cd "$IDENT"`); see each package's README.
`KUBECONFIG` is `~/.kube/alpha.yaml` (the second location outside this folder); `K` always adds `--context alpha`.

## 3. Folders

| Folder | What it is |
|---|---|
| `portal/` (`$REL`) | Portal release package: values, install/upgrade/recover/switch tools, post-renderers (`helm-plugins/`), gates, tests, Bruno, docs (`docs/BE293-FOLDER-GUIDE.md`). `ci/be293-portal-images.yml` is the image-build workflow copy kept for the package checks. |
| `identity/` (`$IDENT`) | Own identity stack (Vault, PostgreSQL, IssuerService, IdentityHub, BDRS) and the two EDC E2E test connectors: values, tools (`identity-vault-be293.sh`, secrets, pins), gates, tests, Bruno `bruno/BE293-Alpha-EDC-E2E/` |
| `charts/` (`$CHARTS`) | Vendored charts: `umbrella-3.17.0/charts/portal-2.6.0.tgz` (the Umbrella 3.17.0 Portal chart the Portal tools pin by sha256), `portal-2.6.0-patched/`, `centralidp-4.2.1-patched/`, `sharedidp-4.2.1-patched/`, `identity/` (identity + connector charts, `patches/`, pinned in `identity/charts.lock.yaml`) |
| `tools/` | `export-standalone.sh`: export to `~/alpha`, and `--check` (drift check) |
| `docs/` | export only: Phase 7 preflight and roadmap v5, copied from the repository's `docs/dev/` (the older roadmaps and discovery reports stay in the repository) |

## 4. Bruno EDC E2E: three port-forwards first

```sh
K -n be293 port-forward --address 127.0.0.1 svc/be293-edc-fv1-controlplane 18181:8081 &   # {{Provider}}  management API
K -n be293 port-forward --address 127.0.0.1 svc/be293-edc-guc-controlplane 18182:8081 &   # {{Consumer}}  management API
K -n be293 port-forward --address 127.0.0.1 svc/be293-edc-fv1-dataplane    18183:8081 &   # {{DataPlane}} = the PROVIDER's data plane
```

Then open `identity/bruno/BE293-Alpha-EDC-E2E/` in Bruno, environment `Alpha env`. The two API keys are secret
variables filled locally from Secrets `be293-edc-fv1-auth` / `be293-edc-guc-auth`, key `management-api-key`.

## 5. Offline gates and tests (no cluster)

```sh
cd "$IDENT" && bash tools/render-identity.sh --release && bash tools/render-edc.sh --release
cd "$REL"   && bash tools/render.sh && bash tools/render-release.sh
for t in "$IDENT"/tests/test_*.rb "$REL"/tests/test_*.rb; do ruby "$t"; done
```

The tests never read your terminal: every script they start runs without a controlling terminal, and the one test that
types a confirmation drives its own pseudo-terminal.

## Not in the export

- Image builds (`portal/tools/build-images.sh`) need a portal-backend Git checkout: set `PORTAL_BACKEND_SOURCE`.
- `portal/ci/archive/` (one-off scripts of past image builds against other Git checkouts), untracked files such as
  `portal/.evidence/` (live snapshots), and the repository's Git history stay in the repository.
  `portal/tests/fixtures/pre-switch/` holds the four values files from before the IdP switch (byte-identical to commit
  `5d548d7^`), so the switch test needs no Git history.
