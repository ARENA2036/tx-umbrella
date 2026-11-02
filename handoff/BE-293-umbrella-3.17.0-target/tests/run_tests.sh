#!/usr/bin/env bash
# Offline tests for the be293-target profile. Never contacts a cluster. Rendered manifests and
# throwaway credentials live only in a private temporary directory that is removed on exit.
#
#   A  DEV baseline: handoff package untouched, DEV renders byte-identical, revision 21 inventory
#   B  helm lint (DEV and target)
#   C  target positive renders and post-render checks
#   D  negative tests: the target profile fails closed
#   E  tool negative tests
#
# Usage: bash tests/run_tests.sh   (from any directory)
set -euo pipefail
export RUBYOPT="${RUBYOPT:+$RUBYOPT }-EUTF-8:UTF-8"   # locale-independent Ruby I/O
cd "$(dirname "$0")/.."
BASE=../BE-293-umbrella-3.17.0
CHART=chart/umbrella
VAULT_CHART=$BASE/charts/umbrella-infrastructure
DEV_VALUES=$BASE/values/values-be293-dev.example.yaml
SECRETREF=$BASE/values/values-be293-identityhub-superuser-secretref.yaml
work="$(mktemp -d "${TMPDIR:-/tmp}/be293-target-test.XXXXXX")"; chmod 700 "$work"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
ko() { echo "FAIL: $*"; fail=$((fail + 1)); }
step() { printf '\n== %s\n' "$*"; }

# Inputs: DEV synthetic secrets (the handoff convention), random target secrets, fixture overlay.
ruby $BASE/tools/make_synthetic_secrets.rb $BASE/values/values-be293-dev.secrets.example.yaml "$work/dev.synthetic.secrets.yaml" >/dev/null
ruby -rsecurerandom -e 'print File.read(ARGV[0]).gsub(/<<SET-FROM-SECRET-STORE:[^>]*>>/) { SecureRandom.alphanumeric(32) }' \
  $BASE/values/values-be293-dev.secrets.example.yaml > "$work/random.secrets.yaml"; chmod 600 "$work/random.secrets.yaml"
cp tests/fixtures/target-platform.ci-fixture.yaml "$work/platform.private.yaml"
ruby tools/build_target_values.rb "$work/platform.private.yaml" "$work/out" >/dev/null
TV="$work/out/values-be293-target.private.yaml"
TVV="$work/out/values-be293-target-vault.private.yaml"
target() { helm template be293-app $CHART -n be293 -f "$TV" "$@"; }

step "A. DEV baseline unchanged"
if git diff --quiet HEAD -- "$BASE" && [ -z "$(git ls-files --others --exclude-standard -- "$BASE")" ]; then
  ok "handoff package $BASE has no changes against HEAD"
else
  ko "handoff package $BASE was modified"
fi
# Chart identity: only the version line of Chart.yaml differs; lock file and vendored packages are identical.
meta_diff="$(diff $BASE/chart/umbrella/Chart.yaml $CHART/Chart.yaml || true)"
if [ "$(printf '%s\n' "$meta_diff" | grep -c '^[<>]')" = 2 ] \
   && printf '%s\n' "$meta_diff" | grep -q '^> version: 3.17.0-be293-target.1$' \
   && cmp -s $BASE/chart/umbrella/Chart.lock $CHART/Chart.lock && diff -rq $BASE/chart/umbrella/charts $CHART/charts >/dev/null; then
  ok "Chart.yaml differs only in version (3.17.0-be293-target.1); Chart.lock and 22 vendored packages identical"
else ko "chart metadata or vendored dependencies differ from the verified chart"; fi
# The vendored chart generates TLS material and some passwords at render time, so two renders of
# the ORIGINAL chart already differ on those lines. A line counts as a difference only when it is
# stable across two original renders and differs in the new chart. The parent chart's version
# label (helm.sh/chart: umbrella-<version>) is mapped back to the verified version and counted.
same_render() { # $1 label, rest: helm values args
  local label=$1; shift
  helm template be293-app $BASE/chart/umbrella -n be293 "$@" > "$work/o1.yaml" 2>/dev/null
  helm template be293-app $BASE/chart/umbrella -n be293 "$@" > "$work/o2.yaml" 2>/dev/null
  helm template be293-app $CHART -n be293 "$@" > "$work/n.yaml" 2>/dev/null
  if ruby -e 'o1, o2, n = ARGV.map { |f| File.readlines(f) }
      abort "line count differs: #{o1.size} vs #{n.size}" unless o1.size == o2.size && o1.size == n.size
      labels = n.count { |l| l.include?("umbrella-3.17.0-be293-target.1") }
      n = n.map { |l| l.gsub("umbrella-3.17.0-be293-target.1", "umbrella-3.17.0") }
      volatile = (0...o1.size).count { |i| o1[i] != o2[i] }
      diff = (0...o1.size).count { |i| o1[i] == o2[i] && o1[i] != n[i] }
      puts "lines=#{o1.size} version-labels=#{labels} generated-volatile=#{volatile} other-differences=#{diff}"; exit(diff.zero? ? 0 : 1)' \
      "$work/o1.yaml" "$work/o2.yaml" "$work/n.yaml" > "$work/same" 2>&1; then
    ok "$label identical to the verified chart ($(grep -c '^kind:' "$work/n.yaml") objects; $(cat "$work/same"))"
  else ko "$label differs from the verified chart: $(cat "$work/same")"; fi
}
same_render "DEV render" -f $DEV_VALUES -f "$work/dev.synthetic.secrets.yaml"
cp "$work/n.yaml" "$work/dev-new.yaml"
same_render "DEV render with SecretRef overlay" -f $DEV_VALUES -f "$work/dev.synthetic.secrets.yaml" -f $SECRETREF
ruby $BASE/tools/render_inventory.rb --normalize-registry < "$work/dev-new.yaml" > "$work/dev-new.json"
ruby $BASE/tools/compare_inventory.rb $BASE/inventory/expected-rev21-inventory.json "$work/dev-new.json" >/dev/null && ok "DEV inventory identical to revision 21 (231 objects)" || ko "DEV inventory differs from revision 21"
helm template be293-vault $VAULT_CHART -n be293 -f $BASE/values/values-be293-vault.example.yaml 2>/dev/null | ruby $BASE/tools/render_inventory.rb > "$work/v.json"
ruby $BASE/tools/compare_inventory.rb $BASE/inventory/expected-vault-inventory.json "$work/v.json" >/dev/null && ok "DEV Vault inventory unchanged" || ko "DEV Vault inventory differs"
dev_fail() { # $1 name, $2 expected message, rest: helm args
  local name=$1 msg=$2; shift 2
  if helm template be293-app $CHART "$@" >/dev/null 2>"$work/err"; then ko "DEV guard: $name accepted"
  elif grep -qF -- "$msg" "$work/err"; then ok "DEV guard: $name rejected"
  else ko "DEV guard: $name failed with an unexpected error: $(grep -m1 Error "$work/err")"; fi
}
dev_fail "namespace portal" "k8s-dev-01 deployment must use namespace be293" -n portal -f $DEV_VALUES -f "$work/dev.synthetic.secrets.yaml"
dev_fail "ClusterIssuer letsencrypt-prod" "requires the approved letsencrypt-dev ClusterIssuer" -n be293 -f $DEV_VALUES -f "$work/dev.synthetic.secrets.yaml" --set be293.platform.clusterIssuer=letsencrypt-prod
dev_fail "empty StorageClass" "requires StorageClass premium-perf1-stackit" -n be293 -f $DEV_VALUES -f "$work/dev.synthetic.secrets.yaml" --set be293.platform.storageClass=
dev_fail "missing approvedRepository" "approvedRepository" -n be293 -f $DEV_VALUES -f "$work/dev.synthetic.secrets.yaml" --set be293.privateImages.approvedRepository=

step "B. helm lint"
helm lint --strict $CHART -n be293 -f $DEV_VALUES -f "$work/dev.synthetic.secrets.yaml" >"$work/lint" 2>&1 && grep -q '0 chart(s) failed' "$work/lint" && ok "lint --strict DEV profile" || ko "lint DEV profile"
helm lint --strict $CHART -n be293 -f "$TV" -f "$work/random.secrets.yaml" >"$work/lint" 2>&1 && grep -q '0 chart(s) failed' "$work/lint" && ok "lint --strict be293-target profile" || ko "lint be293-target profile"
# The Vault chart fails --strict with the DEV overlay too (no templates/ directory); the handoff lints it without --strict.
helm lint $VAULT_CHART -n be293 -f "$TVV" >"$work/lint" 2>&1 && grep -q '0 chart(s) failed' "$work/lint" && ok "lint Vault (target overlay)" || ko "lint Vault target overlay"

step "C. be293-target positive renders"
if target -f "$work/random.secrets.yaml" > "$work/t.yaml" 2>"$work/err"; then ok "target renders ($(grep -c '^kind:' "$work/t.yaml") objects)"; else ko "target render: $(grep -m1 Error "$work/err")"; fi
ruby tools/check_target_render.rb "$TV" < "$work/t.yaml" > "$work/chk" && ok "post-render checks: $(tail -1 "$work/chk")" || { cat "$work/chk"; ko "post-render checks"; }
ruby $BASE/tools/check_placeholders.rb < "$work/t.yaml" >/dev/null && ok "no placeholder or example identifier in target render" || ko "placeholder in target render"
helm template be293-vault $VAULT_CHART -n be293 -f "$TVV" 2>/dev/null | ruby tools/check_target_render.rb "$TV" --vault > "$work/chk" && ok "Vault post-render checks: $(tail -1 "$work/chk")" || { cat "$work/chk"; ko "Vault post-render checks"; }
target -f "$work/random.secrets.yaml" -f $SECRETREF >/dev/null 2>"$work/err" && ok "target accepts credentials moved to SecretRefs (superuser overlay)" || ko "target rejects SecretRef overlay: $(grep -m1 Error "$work/err")"
# Same objects as DEV revision 21 plus the four external Ingresses, once the fixture coordinates are mapped back.
sed -e 's#registry\.ci-fixture\.internal#registry.example.invalid#g' -e 's#ci-fixture-pull#be293-dockerhub-pull#g' "$work/t.yaml" \
  | ruby $BASE/tools/render_inventory.rb --normalize-registry > "$work/t.json"
ruby $BASE/tools/compare_inventory.rb $BASE/inventory/expected-rev21-inventory.json "$work/t.json" > "$work/cmp" || true
if grep -q 'expected=231 actual=235 missing=0 extra=4' "$work/cmp" && [ "$(grep -c '^  ' "$work/cmp")" = 4 ] && [ "$(grep -c '^  EXTRA   Ingress/' "$work/cmp")" = 4 ]; then
  ok "target = revision 21 inventory + 4 external Ingresses, no other difference"
else cat "$work/cmp"; ko "target inventory differs from revision 21 beyond the 4 Ingresses"; fi
# The chart-rendered Ingresses equal manifests/10-13 apart from namespace, host zone, class, issuer and labels.
ruby -ryaml -e '
  norm = ->(d) { s = d["spec"].to_yaml.gsub("be293.ci-fixture.internal", "ZONE").gsub("be293.dev.example.invalid", "ZONE").gsub("ci-fixture-ingress", "CLASS").gsub("nginx", "CLASS")
                 a = (d.dig("metadata", "annotations") || {}).to_yaml.gsub("be293.ci-fixture.internal", "ZONE").gsub("be293.dev.example.invalid", "ZONE").gsub("letsencrypt-prod", "ISSUER").gsub("letsencrypt-dev", "ISSUER")
                 [s, a] }
  rendered = YAML.load_stream(File.read(ARGV[0])).compact.select { |d| d["kind"] == "Ingress" }.map { |d| [d["metadata"]["name"], norm.(d)] }.to_h
  bad = Dir[File.join(ARGV[1], "1[0-3]-*.yaml")].map { |f| d = YAML.load_file(f); n = d["metadata"]["name"]; rendered[n] == norm.(d) ? nil : n }.compact
  puts bad.join(" "); exit(bad.empty? ? 0 : 1)' "$work/t.yaml" $BASE/manifests > "$work/ing" && ok "external Ingresses match DEV manifests 10-13 (spec and annotations)" || ko "Ingress drift: $(cat "$work/ing")"
target -f "$work/random.secrets.yaml" --set be293.target.externalDns=false 2>/dev/null | grep -q 'external-dns.alpha.kubernetes.io' && ko "externalDns=false still renders ExternalDNS annotations" || ok "externalDns=false renders no ExternalDNS annotations"

step "D. be293-target fails closed"
neg() { # $1 name, $2 expected message fragment, rest: extra helm args (rendered with the fixture overlay)
  local name=$1 msg=$2; shift 2
  if helm template be293-app $CHART -n be293 "$@" >/dev/null 2>"$work/err"; then ko "$name: accepted"
  elif grep -qF -- "$msg" "$work/err"; then ok "$name"
  else ko "$name: unexpected error: $(grep -m1 Error "$work/err")"; fi
}
R=(-f "$TV" -f "$work/random.secrets.yaml")
neg "sanitized example as-is"              "reserved or example name suffix .invalid" -f values/values-be293-target.example.yaml -f "$work/random.secrets.yaml"
neg "namespace portal (-n)"                "dedicated namespace be293" -n portal "${R[@]}"
neg "target.namespace portal"              "be293.target.namespace=be293" "${R[@]}" --set be293.target.namespace=portal
neg "ClusterIssuer letsencrypt-dev"        "ClusterIssuer be293.target.clusterIssuer=letsencrypt-prod" "${R[@]}" --set be293.target.clusterIssuer=letsencrypt-dev
neg "ClusterIssuer missing"                "ClusterIssuer be293.target.clusterIssuer=letsencrypt-prod" "${R[@]}" --set be293.target.clusterIssuer=
neg "storage policy missing"               "storageClassPolicy=cluster-default" "${R[@]}" --set be293.target.storageClassPolicy=
neg "global named StorageClass"            "global.storageClass must be empty" "${R[@]}" --set global.storageClass=premium-perf1-stackit
neg "IdentityHub DB StorageClass \"-\""    "identity-hub-postgres.postgresql.persistence.storageClass must be empty" "${R[@]}" --set identity-and-trust-bundle.identity-hub-postgres.postgresql.persistence.storageClass=-
neg "StorageClass \"-\" on a claim path"   "bpdm.postgres.primary.persistence.storageClass must be empty" "${R[@]}" --set bpdm.postgres.primary.persistence.storageClass=-
neg "StorageClass \"-\" elsewhere"         "forbids storageClass \"-\"" "${R[@]}" --set semantic-hub.hub.persistence.storageClass=-
neg "named StorageClass on Portal DB"      "portal.postgresql.primary.persistence.storageClass must be empty" "${R[@]}" --set portal.postgresql.primary.persistence.storageClass=standard
neg "named StorageClass on twin DB"        "digital-twin-bundle.postgresql.primary.persistence.storageClass must be empty" "${R[@]}" --set tx-data-provider.digital-twin-bundle.postgresql.primary.persistence.storageClass=fast
neg "DEV overlay layered underneath"       "must not carry the k8s-dev-01 be293.platform" -f $DEV_VALUES "${R[@]}"
neg "DEV platform value"                   "must not carry the k8s-dev-01 be293.platform.clusterIssuer" "${R[@]}" --set be293.platform.clusterIssuer=letsencrypt-dev
neg "DEV static-token switch"              "forbids the DEV switch be293.devVaultStaticTokens" "${R[@]}" --set be293.devVaultStaticTokens.enabled=true
neg "CoreDNS patch enabled"                "coreDnsPatch.enabled=false" "${R[@]}" --set be293.coreDnsPatch.enabled=true
neg "DNS zone missing"                     "be293.target.dnsZone as a lower-case DNS name" "${R[@]}" --set be293.target.dnsZone=
neg "DNS zone .test"                       "reserved or example name suffix .test" "${R[@]}" --set be293.target.dnsZone=be293.corp.test
neg "DNS zone example.com"                 "reserved or example name suffix .example.com" "${R[@]}" --set be293.target.dnsZone=be293.example.com
neg "routing zone mismatch"                "be293.routing.dnsZone to equal" "${R[@]}" --set be293.routing.dnsZone=other.ci-fixture.internal
neg "wallet host outside zone"             "wallet.identityHub.shared.host=identity-hub" "${R[@]}" --set wallet.identityHub.shared.host=identity-hub.other.internal
neg "ingress class missing"                "be293.target.ingressClass" "${R[@]}" --set be293.target.ingressClass=
neg "externalDns not a boolean"            "be293.target.externalDns=true|false" "${R[@]}" --set-string be293.target.externalDns=yes
neg "invalid DID BPN"                      "is not a valid BPNL" "${R[@]}" --set 'be293.target.externalIngresses.identityHubDidBpns={BPNX0001}'
neg "no DID BPNs"                          "identityHubDidBpns" "${R[@]}" --set 'be293.target.externalIngresses.identityHubDidBpns=null'
neg "registry example.com"                 "reserved or example name suffix .example.com" "${R[@]}" --set be293.target.registryHost=registry.example.com
neg "repository outside registry"          "be293.target.imageRepository as <registryHost>/<path>" "${R[@]}" --set be293.target.imageRepository=other.ci-fixture.internal/be293/x
neg "pull Secret missing"                  "be293.target.pullSecretName" "${R[@]}" --set be293.target.pullSecretName=
neg "privateImages drift"                  "be293.privateImages.{registry,repository,pullSecretName}" "${R[@]}" --set be293.privateImages.pullSecretName=other-pull
neg "digest pinning disabled"              "requireDigestReferences=true" "${R[@]}" --set be293.privateImages.requireDigestReferences=false
neg "pullPolicy Never"                     "pullPolicy: Never" "${R[@]}" --set smtp4dev.image.pullPolicy=Never
neg "address in another namespace"         "in-cluster address in another namespace (.portal.svc.cluster.local)" "${R[@]}" --set wallet.identityHub.shared.stsUrl=http://sts.portal.svc.cluster.local/api/sts
neg "operator marker left"                 "<<SET-BY-OPERATOR" "${R[@]}" --set be293.target.vaultAddress='<<SET-BY-OPERATOR:vault-address>>'
neg "Helm hooks not approved"              "helmHooksApproved=true" "${R[@]}" --set be293.target.helmHooksApproved=false
neg "secret delivery ExternalSecrets"      "secretDelivery=preprovisioned-kubernetes-secrets" "${R[@]}" --set be293.target.secretDelivery=external-secrets
# Fails before the guard is reached: templates/vault-secretstore.yaml dereferences an unset .Values.vault.
neg "External Secrets enabled"             "vault-secretstore.yaml" "${R[@]}" --set external-secrets.enabled=true
neg "Vault address missing"                "be293.target.vaultAddress" "${R[@]}" --set be293.target.vaultAddress=
neg "Vault auth mode"                      "vaultAuthMode=secret-backed-static-token" "${R[@]}" --set be293.target.vaultAuthMode=token
neg "embedded connector Vault"             "embedded connector Vault for tx-data-provider" "${R[@]}" --set tx-data-provider.dataspace-connector-bundle.vault.enabled=true
neg "inline Vault token"                   "vaultToken to stay empty" "${R[@]}" --set wallet.identityHub.shared.vaultToken=s.0123456789abcdefghij
neg "no secrets overlay"                   "is a placeholder or a weak value" -f "$TV"
neg "unfilled secrets example"             "is a placeholder or a weak value" -f "$TV" -f $BASE/values/values-be293-dev.secrets.example.yaml
neg "synthetic test secrets"               "synthetic-" -f "$TV" -f "$work/dev.synthetic.secrets.yaml"
neg "weak credential"                      "portal.postgresql.auth.password is a placeholder or a weak value" "${R[@]}" --set portal.postgresql.auth.password=changeme
neg "short credential"                     "portal.postgresql.auth.password is shorter than 16" "${R[@]}" --set portal.postgresql.auth.password=Short1Short2abc
neg "missing credential"                   "portal.postgresql.auth.password is missing" "${R[@]}" --set portal.postgresql.auth.password=null
neg "weak inline value beside a SecretRef" "identityhub.env.EDC_IH_API_SUPERUSER_KEY is a placeholder or a weak value" "${R[@]}" -f $SECRETREF --set identity-and-trust-bundle.identity-hub-postgres.identityhub.env.EDC_IH_API_SUPERUSER_KEY=changeme

step "E. Tool negative tests"
bad_input() { # $1 name, $2 yaml fragment overriding the fixture
  printf '%s\n' "$2" | ruby -ryaml -e 'b = YAML.load_file(ARGV[0]); b.merge!(YAML.safe_load($stdin.read)); File.write(ARGV[1], b.to_yaml)' tests/fixtures/target-platform.ci-fixture.yaml "$work/bad.private.yaml"
  ruby tools/build_target_values.rb "$work/bad.private.yaml" "$work/bad" >/dev/null 2>&1 && ko "build tool accepted $1" || ok "build tool rejects $1"
}
bad_input "an example DNS zone"        'dnsZone: be293.example.invalid'
bad_input "an unfilled marker"         'ingressClass: "<<SET-BY-OPERATOR:ingress-class>>"'
bad_input "a non-boolean externalDns"  'externalDns: "yes"'
bad_input "a repository outside the registry" 'imageRepository: elsewhere.internal/x'
bad_input "unapproved hooks"           'helmHooksApproved: false'
ruby tools/build_target_values.rb values/target-platform.example.yaml "$work/bad" >/dev/null 2>&1 && ko "build tool accepted a non-private input name" || ok "build tool requires a git-ignored *.private.yaml input"
{ cat "$work/t.yaml"; printf -- '---\napiVersion: v1\nkind: PersistentVolumeClaim\nmetadata:\n  name: probe-empty\nspec:\n  storageClassName: ""\n---\napiVersion: v1\nkind: PersistentVolumeClaim\nmetadata:\n  name: probe-named\nspec:\n  storageClassName: standard\n'; } \
  | ruby tools/check_target_render.rb "$TV" > "$work/chk" && ko "render check accepted storageClassName" || { [ "$(grep -c 'sets storageClassName' "$work/chk")" = 2 ] && ok "render check rejects storageClassName \"\" and a named class" || ko "render check findings: $(grep -c FINDING "$work/chk")"; }
sed 's/cert-manager.io\/cluster-issuer: "letsencrypt-prod"/cert-manager.io\/cluster-issuer: "letsencrypt-staging"/' "$work/t.yaml" | ruby tools/check_target_render.rb "$TV" >/dev/null && ko "render check accepted another ClusterIssuer" || ok "render check rejects another ClusterIssuer"

echo; echo "passed=$pass failed=$fail"
[ "$fail" = 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
