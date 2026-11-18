# BE-293 — Phase 1 read-only discovery kit

**For:** Claude Code in `~/Projects/ARENA2036/BE293_ALPHA/tx-umbrella`
**Roadmap:** `BE-293_Alpha_Own_IAM_and_Identity_Stack_Roadmap_v2.md`, Phase 1
**Gate state:** Gate 0 NOT passed → Phase 1 only. Read-only everywhere. Nothing is modified, nothing is pushed.

---

## Ground rules for this phase

- No file, branch, cluster resource or Git state is modified.

**Three commands in this kit are not strictly read-only. They are the only ones.**

| Where | What it does | Why it is acceptable |
|---|---|---|
| Setup + item 8 | `mktemp -d` and `tar xzf` write extracted charts to a scratch directory | Writes land outside the repository and outside the cluster; nothing in Git or `be293` changes. Delete the scratch directory when the report is written. |
| **Item 12b** | `kubectl exec` into the Portal PostgreSQL pod | **`pods/exec` is `create`, not `get`.** SELECT-only SQL with `default_transaction_read_only=on`, but it still opens a shell in a live pod → **requires explicit approval before running.** |
| Item 6 | `docker manifest inspect` | Outbound read against the registry; no local or cluster state changes. May need registry auth or hit rate limits. |

Everything else is `get` / `describe` / `logs`, `grep`, `find`, `cat`, `dig`, `helm show`, and `tar tzf`
(list only).
- Cluster access always `--kubeconfig ~/.kube/alpha.yaml --context alpha`, verbs limited to `get`, `describe`,
  `logs`. Prefer the existing guarded wrappers in `alpha/portal-release-prepared/tools/` where one exists for
  the job; fall back to raw `kubectl` only with the explicit flags above.
- **Secrets: key names only.** Never `base64 -d`. Never echo a value. The commands below are written so that a
  value cannot appear in output — do not "improve" them.
- Every item is reported as: **finding / evidence (`file:line` or command + relevant output) / confirmed or
  inferred**. Inferred is an acceptable answer. A guess presented as a finding is not.
- If a command returns nothing, that is itself a finding — record the command and the empty result.

Set once per shell. **zsh does not treat `#` as a comment on an interactive command line** unless
`interactive_comments` is set, so the first line is required before pasting any block from this kit —
otherwise comment text is parsed as arguments.

```bash
setopt interactive_comments 2>/dev/null || true

export ROOT="$HOME/Projects/ARENA2036/BE293_ALPHA/tx-umbrella"
export UMB="$ROOT/handoff/BE-293-umbrella-3.17.0/chart/umbrella"
export REL="$ROOT/alpha/portal-release-prepared"
export BE="$HOME/Projects/ARENA2036/portal-backend-await-fix"
export WORK=$(mktemp -d)
cd "$ROOT"

K() { kubectl --kubeconfig "$HOME/.kube/alpha.yaml" --context alpha "$@"; }
```

`K` is a **function, not a variable**, deliberately: zsh does not word-split unquoted parameter expansions, so
a `$K="kubectl --flags"` variable expands to a single command name and fails. A function behaves identically
in zsh and bash. It is also safer — the kubeconfig and context cannot be dropped by a careless quote.

A function lives only in the current shell. If a step runs in a fresh non-interactive shell, re-define it
there or spell `kubectl` out with both flags. **Never run a bare `kubectl`** — the default context is not
Alpha.

Verify before running anything else — every path must exist and the context must be `alpha`:

```bash
for p in "$ROOT" "$UMB" "$REL" "$BE" "$WORK"; do
  [ -e "$p" ] && echo "ok   $p" || echo "MISSING  $p"
done
K config current-context
K -n be293 get ns be293 -o name
```

---

# Part 1B — IAM discovery (do this first; item 11 is the critical path)

## Item 11 — D1: can the Portal keep a separate token endpoint for outbound calls?

**This answers whether the project costs +0 or +3–4 days. Do it first.**

```bash
# 1. How does the backend obtain outbound service tokens?
grep -rn --include=*.cs -i "KeycloakTokenAddress\|TokenAddress\|ITokenService\|GetTokenAsync" \
  "$BE/src" | head -40

# 2. The settings class behind BPDM calls
grep -rln --include=*.cs -i "BpdmServiceSettings\|class Bpdm.*Settings" "$BE/src"

# 3. Every appsettings key that carries a token endpoint
grep -rn --include=appsettings*.json -i "tokenaddress\|keycloak\|clientid\|grant_type\|granttype" \
  "$BE/src" | grep -vi "secret" | head -60

# 4. What the processes worker actually ships with
find "$BE/src" -path "*Processes.Worker*" -name "appsettings*.json" -exec echo "== {}" \; -exec cat {} \;
```

**Record:** for BPDM, and for each other outbound integration found (BPN Discovery, Discovery Finder,
SD Factory, Clearing House): the setting name that holds the token endpoint, whether it is independent of the
login authority, and the `file:line` that proves it.

**Then answer, in one sentence:** *D1-a is / is not possible without a code change, because …*

## Item 7 — Chart inventory

```bash
ls -la "$UMB/charts/" | grep -i -E "centralidp|sharedidp|portal|bpdm"
for c in "$UMB"/charts/centralidp-*.tgz "$UMB"/charts/sharedidp-*.tgz; do
  [ -e "$c" ] || continue
  echo "=== $c"
  helm show chart "$c"
  tar tzf "$c" | head -40
done
grep -n -A4 -i -E "centralidp|sharedidp" "$UMB/Chart.yaml"
```

**Record:** chart name and version, Keycloak image and tag, realm-seeding image and tag, dependency
conditions, and whether each chart has its own `templates/` (→ installable standalone) or only works as an
umbrella subchart.

## Item 8 — Realm seed content

```bash
for c in "$UMB"/charts/centralidp-*.tgz "$UMB"/charts/sharedidp-*.tgz; do
  [ -e "$c" ] || continue
  n=$(basename "$c" .tgz); mkdir -p "$WORK/$n"; tar xzf "$c" -C "$WORK/$n"
done
find "$WORK" -name values.yaml -exec echo "== {}" \; -exec cat {} \;
find "$WORK" -iname "*realm*" -o -iname "*seed*" | head -40
grep -rn -i "hostname\|proxy\|KC_\|http-enabled\|frontendUrl" "$WORK" | head -40
```

**Record:** realm names; the clients and technical service accounts the seed creates; which values control
redirect URIs, web origins and frontend URL; the SMTP block in the SharedIDP seed; password policy; the
seeding job's resource limits (compare against the known OOM history).

## Item 9 — Secret surface

```bash
grep -rn -i "secret\|password\|credential" "$WORK"/*/*/values.yaml | grep -v "^Binary" | head -60
# live Secret key names in be293 — names only, never values
for s in $(K -n be293 get secret -o name); do
  echo "== $s"; K -n be293 get "$s" -o json | jq -r '.data | keys[]' 
done
```

**Record:** every client secret and admin credential the seeds consume, and **how** it is supplied (plain
values key / existing Secret reference / file). This determines the Phase 2 secret design. Key names only.

## Item 10 — Portal configuration surface (fills Appendix A)

```bash
grep -rn -i -E "centralidp|sharedidp|keycloak|realm|jwtbearer|metadataaddress|validissuer|validaudience|clientid" \
  "$REL/values-be293-portal.yaml" "$REL"/values-be293-portal.*.yaml
grep -rn -i -E "centralidp|sharedidp|authRealm|clientId|metadataAddress|validIssuer" \
  "$UMB"/charts/portal-*.tgz 2>/dev/null || { mkdir -p "$WORK/portal"; tar xzf "$UMB"/charts/portal-*.tgz -C "$WORK/portal"; \
  grep -rn -i -E "centralidp|sharedidp|authRealm|clientId|metadataAddress|validIssuer" "$WORK/portal" | head -80; }
# live confirmation of what is actually configured
K -n be293 get cronjob be293-portal-processes-worker -o json \
  | jq -r '..|objects|select(.name? and .value?)
      | "\(.name)=\(if (.value|test("^https?://")) then .value else "[redacted]" end)"' \
  | grep -i -E "centralidp|sharedidp|keycloak|realm|idp" 
K -n be293 get deploy -o json \
  | jq -r '..|objects|select(.name? and .value?)
      | "\(.name)=\(if (.value|test("^https?://")) then .value else "[redacted]" end)"' \
  | grep -i -E "centralidp|sharedidp|keycloak|realm|idp"
```

**Record:** fill every row of Appendix A in the roadmap: key, current host, target host, `file:line`. Flag any
row where the chart derives several settings from one address — those are the ones that break on a split.

## Item 12 — Portal DB binding to Keycloak identifiers

### 12a — From source (read-only, run now)

```bash
grep -rn --include=*.cs -i "iam_identity_provider\|iam_users\|iam_clients\|iam_service_accounts\|IdentityProviderId" \
  "$BE/src" | head -40
```

### 12b — Database inspection — **NOT read-only in the RBAC sense. Needs explicit approval.**

`kubectl exec` is `create` on `pods/exec`, not `get`. The SQL below is SELECT-only and belted with
`default_transaction_read_only=on`, so it cannot write, but it does open a shell in a live pod and therefore
falls outside this phase's "read verbs only" rule. **Ask before running it.** Item 12a may already answer the
question from source alone; prefer that.

First confirm the password variable name inside the pod — names only, no values:

```bash
K -n be293 get statefulset be293-portal-postgresql -o json \
  | jq -r '..|objects|select(.name? and (.value? or .valueFrom?))|.name' | grep -i -E "password|user|db"
```

Then, with the variable resolved **inside** the container so no secret touches our command line or shell
history (substitute the real variable name if it differs):

```bash
K -n be293 exec be293-portal-postgresql-0 -- bash -c '
  PGPASSWORD="$POSTGRES_PASSWORD" PGOPTIONS="-c default_transaction_read_only=on" \
  psql -U postgres -d portal -A -t \
    -c "\dt portal.*" \
    -c "select table_name, column_name from information_schema.columns
         where table_schema = '"'"'portal'"'"' and column_name ilike '"'"'%iam%'"'"'
            or table_name ilike '"'"'%identity_provider%'"'"' order by 1,2;"'
```

Note `-it` is deliberately absent (no TTY needed) and the table names from the roadmap are **assumptions** —
report what the catalogue actually contains rather than retrying variants of a guess.

**Record:** which tables/columns hold realm aliases, Keycloak user IDs and client IDs; how many rows exist per
company; and what breaks for each if the realm changes. This decides D4 (clean re-seed vs. row cleanup).

## Item 13 — A07 and the `0342` 401, on our own IDPs

```bash
grep -rn --include=*.cs -i "idp2\|alias\|CreateSharedIdpServiceAccount\|CreateOwnIdpAsync" "$BE/src" | head -40
```

**Record:** whether the alias collision and the activation 401 are purely consequences of a shared realm
namespace, or whether a Portal-side fix is still required once we own the realms. Be explicit about which.

---

# Part 1A — Identity stack discovery

## Item 1 — Worker identity and BDRS settings

```bash
grep -rn --include=*.cs -i "APPLICATIONCHECKLIST__IDENTITYHUB\|IdentityHubSettings\|BpnDidResolver" "$BE/src" | head -40
K -n be293 get cronjob be293-portal-processes-worker -o json \
  | jq -r '..|objects|select(.name? and .value?)
      | "\(.name)=\(if (.value|test("^https?://")) then .value else "[redacted]" end)"' \
  | grep -i -E "IDENTITYHUB|BPNDIDRESOLVER"
```

**Record:** which checklist step calls BDRS, with what payload, and whether the onboarding flow can complete
without it. This decides own-BDRS vs. skip.

## Item 2 — The false `DONE` on `BPNL000000000342`

```bash
grep -rn --include=*.cs -i "BPNL_CREDENTIAL\|SetApplicationChecklistEntry\|ProcessStepStatusId.DONE" "$BE/src" | head -40
K -n be293 get cronjob be293-portal-processes-worker -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[*].image}'
```

**Record:** every code path that can set `BPNL_CREDENTIAL = DONE`, which one fires without a successful
issuance, and the image digest/commit the 2026-11-07 Worker was built from.

## Item 3 — Caller of `RequestCredentialAsync`

```bash
grep -rn --include=*.cs "RequestCredentialAsync\|RegisterHolderWithIssuerAsync\|GetCredentialRequestStateAsync" "$BE/src"
```

**Record:** which values are in scope at the call site — application ID, approval timestamp, BPN — for the
Phase 4 `HolderProperties` work.

## Item 4 — DEV blueprint

```bash
D=$HOME/Backup/Projects/public-tractus-x-umbrella
ls "$D/charts/identity-and-trust-bundle/"
sed -n '1,200p' "$D/charts/tx-data-provider/templates/post-install-identityhub-seed.yaml"
grep -rn -i "participants/\|v1alpha\|base64\|holderPid" "$D/charts/tx-data-provider/templates/post-install-identityhub-seed.yaml"
```

**Record:** components, images, ports, settings, secrets used, and how participant IDs appear in URLs — plain
vs. base64 (0.17.0 admin API uses the **plain** ID).

## Item 5 — Alpha environment preconditions

```bash
for h in centralidp-be293 sharedidp-be293 issuer-be293 identityhub-be293; do
  echo "== $h"; dig +short "$h.test.tractus-x.com"; done
dig +short portal-be293.test.tractus-x.com   # known-good reference
K -n be293 get networkpolicy
K -n be293 get ingress -o wide
```

**Record:** whether the four new names already resolve (wildcard) or need to be created, and the current
NetworkPolicy posture in `be293`.

## Item 6 — Official image sufficiency

```bash
docker manifest inspect tractusx/issuerservice:0.4.1 >/dev/null && echo "issuerservice 0.4.1 pullable"
docker manifest inspect tractusx/identityhub:0.4.1  >/dev/null && echo "identityhub 0.4.1 pullable"
grep -rn -i "callback\|status.*callback" "$HOME/Backup/Projects/public-tractusx-identityhub" --include=*.java | head -20
```

**Record:** confirm the official images carry `issuerservice-holder-attestations` and
`issuerservice-issuance-rules`, and that the DEV custom IdentityHub image added only the Portal credential
callback the Worker no longer needs (it polls).

---

# Report skeleton

Write to `docs/dev/BE-293-phase1-discovery-report.md`. One section per item, in this shape:

```markdown
## Item N — <title>

**Finding:**

**Evidence:**
- `path/to/file.ext:123` — <the line or excerpt that proves it>
- command: `...`
  output (relevant lines only):

**Status:** CONFIRMED | INFERRED
**Consequence for the roadmap:** <which phase/decision this changes, if any>
```

Close the report with:

| Decision | Answer from Phase 1 | Evidence item |
|---|---|---|
| D1 (outbound token trust) | a / b / c | 11 |
| D2 (hostnames available) | yes / no | 5 |
| D4 (Portal DB: re-seed vs. clean) | recommendation | 12 |
| BDRS (own / skip / keep shared) | recommendation | 1 |
| Custom images needed | yes / no | 6 |

**Then stop. Gate 1.** No ADR, no chart work, no branch, until the report is reviewed.
