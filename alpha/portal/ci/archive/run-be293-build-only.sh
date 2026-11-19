#!/usr/bin/env bash
# BE-293 Phase 3: push the two reviewed feature branches and run ONE build-only (push=false) image workflow.
#
#   bash ci/run-be293-build-only.sh [--allow-skipped-integration]
#
# Stops on the first mismatch. Never: force-push, merge, push=true, Docker push, kubectl, Helm.
#   1. preflight (read-only): backend branch/commit/parent/clean worktree/patch identity, remote heads,
#      gh authentication (status only, no token output)
#   2. native tests in the backend worktree; the 4 Testcontainers integration tests need Docker - without
#      Docker they are reported SKIPPED and the script stops unless --allow-skipped-integration is given
#   3. tx-umbrella: separate worktree + branch from origin/fix/be293-final-images (your current checkout is
#      not touched), apply the reviewed workflow patch, verify only SOURCE_COMMIT changed, commit
#   4. typed confirmation, then push exactly the two branches (no force) and verify the remote SHAs
#   5. dispatch be293-portal-images.yml with push=false on the workflow branch, watch it, save evidence
# Evidence: $EVIDENCE (run JSON, full log, test summary). GitHub masks secrets in logs; push=false never logs
# in to a registry.
set -euo pipefail

BASE=ad459ee711ecaa9a43535a513bd9db83b640a8ff
NEW=274096a965c10d65a96d8c077a60b7680176aff7
BRANCH=fix/BE-293-retrigger-validate-did-in-progress
PATCH_ID=3924685d22c28b2dc2445753726ce8d4c585755c
TX_BASE=cf147aeedb91405fb4f5099789f112c1f8271b24
TX_BRANCH=fix/be293-retrigger-images
WORKFLOW=be293-portal-images.yml
TX_REPO=ARENA2036/tx-umbrella
SRC="${PORTAL_BACKEND_REPO:-$HOME/Projects/ARENA2036/portal-backend}"
WT="${PORTAL_BACKEND_RETRIGGER_WORKTREE:-$HOME/Projects/ARENA2036/portal-backend-retrigger-fix}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TX="$(cd "$HERE/../.." && pwd)"
TX_WT="${TX_WORKTREE:-$HOME/Projects/ARENA2036/BE293_ALPHA/tx-umbrella-retrigger-images}"
TX_PATCH="$HERE/ci/tx-umbrella-be293-portal-images-274096a9.patch"
EVIDENCE="$HERE/.evidence/build-only-$(date -u +%Y%m%dT%H%M%SZ)"
ALLOW_SKIP=0
[[ "${1:-}" == "--allow-skipped-integration" ]] && ALLOW_SKIP=1
[[ -z "${1:-}" || "$ALLOW_SKIP" == 1 ]] || { echo "usage: run-be293-build-only.sh [--allow-skipped-integration]" >&2; exit 2; }

die() { echo "STOP: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
confirm() {
  { exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation"
  printf 'Type exactly "%s": ' "$1" >&3; local a=""; read -r a <&3 || true; exec 3>&-
  [[ "$a" == "$1" ]] || die "confirmation did not match; nothing further done"
}
remote_head() { GIT_TERMINAL_PROMPT=0 git -C "$1" ls-remote origin "refs/heads/$2" | cut -f1; }
umask 077
mkdir -p "$EVIDENCE"

step "1 preflight (read-only)"
[[ "$(git -C "$SRC" rev-parse "refs/heads/$BRANCH")" == "$NEW" ]] || die "$BRANCH is not at $NEW"
[[ "$(git -C "$SRC" rev-parse "$NEW^")" == "$BASE" ]] || die "parent of $NEW is not $BASE"
[[ "$(git -C "$WT" rev-parse HEAD)" == "$NEW" && -z "$(git -C "$WT" status --porcelain)" ]] || die "worktree $WT not clean at $NEW"
[[ "$(git -C "$SRC" diff "$BASE" "$NEW" | git patch-id --stable | cut -d' ' -f1)" == "$PATCH_ID" ]] || die "commit content differs from the reviewed patch"
[[ "$(git -C "$SRC" diff --name-only "$BASE" "$NEW" | wc -l | tr -d ' ')" == 4 ]] || die "commit does not change exactly 4 files"
rb="$(remote_head "$SRC" "$BRANCH")"; [[ -z "$rb" || "$rb" == "$NEW" ]] || die "remote $BRANCH exists at $rb (refusing to overwrite)"
[[ "$(remote_head "$TX" fix/be293-final-images)" == "$TX_BASE" ]] || die "remote fix/be293-final-images is not $TX_BASE"
rt="$(remote_head "$TX" "$TX_BRANCH")"; [[ -z "$rt" ]] || die "remote $TX_BRANCH already exists at $rt"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
gh api "repos/$TX_REPO/actions/workflows/$WORKFLOW" --jq .state >/dev/null || die "cannot read $WORKFLOW in $TX_REPO"
echo "OK   backend $BRANCH = $NEW (parent $BASE, 4 files, reviewed patch), remotes as expected, gh authenticated"

step "2 native tests (backend worktree)"
cd "$WT"
: > "$EVIDENCE/tests.txt"
for p in tests/processes/ApplicationChecklist.Library.Tests tests/externalsystems/BpnDidResolver.Library.Tests \
         tests/processes/ApplicationChecklist.Executor.Tests; do
  dotnet test "$p" --nologo -v q 2>&1 | tee -a "$EVIDENCE/tests.txt" | grep -E 'Passed!|Failed!' || die "tests failed: $p"
done
INTEGRATION='FullyQualifiedName~ConnectorsControllerIntegrationTests|FullyQualifiedName~PublicUrl'
dotnet test tests/administration/Administration.Service.Tests --nologo -v q --filter "FullyQualifiedName!~ConnectorsControllerIntegrationTests&FullyQualifiedName!~PublicUrl" \
  2>&1 | tee -a "$EVIDENCE/tests.txt" | grep -E 'Passed!|Failed!' || die "Administration.Service.Tests (unit) failed"
if docker info >/dev/null 2>&1; then
  dotnet test tests/administration/Administration.Service.Tests --nologo -v q --filter "$INTEGRATION" \
    2>&1 | tee -a "$EVIDENCE/tests.txt" | grep -E 'Passed!|Failed!' || die "Administration.Service.Tests (Testcontainers integration) failed"
  echo "integration: EXECUTED" | tee -a "$EVIDENCE/tests.txt"
else
  echo "integration: SKIPPED (Docker not available) - 4 Testcontainers tests NOT executed" | tee -a "$EVIDENCE/tests.txt"
  [[ "$ALLOW_SKIP" == 1 ]] || die "Docker-dependent integration tests not executed (start Docker, or rerun with --allow-skipped-integration)"
fi
cd "$HERE"

step "3 tx-umbrella workflow branch (separate worktree)"
[[ ! -e "$TX_WT" ]] || die "$TX_WT already exists"
git -C "$TX" fetch -q origin fix/be293-final-images
[[ "$(git -C "$TX" rev-parse FETCH_HEAD)" == "$TX_BASE" ]] || die "fetched fix/be293-final-images is not $TX_BASE"
git -C "$TX" worktree add -q -b "$TX_BRANCH" "$TX_WT" "$TX_BASE"
git -C "$TX_WT" apply --check "$TX_PATCH"
git -C "$TX_WT" apply --index "$TX_PATCH"
[[ "$(git -C "$TX_WT" diff --cached --numstat)" == "$(printf '1\t1\t.github/workflows/%s' "$WORKFLOW")" ]] || die "workflow patch changed more than one line"
git -C "$TX_WT" diff --cached -U0 | grep -qx "+  SOURCE_COMMIT: $NEW" || die "SOURCE_COMMIT not set to $NEW"
wf="$TX_WT/.github/workflows/$WORKFLOW"
grep -q 'default: false' "$wf" && grep -q 'provenance: mode=max' "$wf" && grep -q 'sbom: true' "$wf" \
  && grep -q 'tags are immutable' "$wf" && grep -q 'version: v0.76.1' "$wf" && grep -q 'Verify BE-293 migrations' "$wf" \
  || die "workflow supply-chain checks missing"
git -C "$TX_WT" commit -q -F - <<EOF
ci(be293): build Portal images from portal-backend ${NEW:0:9}

Point the isolated BE-293 Portal image workflow at ARENA2036/portal-backend
$NEW (ad459ee7 + DID validation retrigger fix). Only SOURCE_COMMIT changes.
EOF
TX_NEW="$(git -C "$TX_WT" rev-parse HEAD)"
echo "OK   $TX_BRANCH = $TX_NEW (parent $TX_BASE, SOURCE_COMMIT only)"

step "4 push the two approved branches (no force)"
echo "  ARENA2036/portal-backend  $BRANCH -> $NEW"
echo "  $TX_REPO  $TX_BRANCH -> $TX_NEW"
confirm "push 2 branches"
git -C "$SRC" push origin "refs/heads/$BRANCH:refs/heads/$BRANCH"
git -C "$TX_WT" push origin "refs/heads/$TX_BRANCH:refs/heads/$TX_BRANCH"
[[ "$(remote_head "$SRC" "$BRANCH")" == "$NEW" ]] || die "remote $BRANCH is not $NEW after push"
[[ "$(remote_head "$TX" "$TX_BRANCH")" == "$TX_NEW" ]] || die "remote $TX_BRANCH is not $TX_NEW after push"
echo "OK   remote heads verified"

step "5 build-only workflow (push=false)"
confirm "dispatch push=false"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
gh workflow run "$WORKFLOW" --repo "$TX_REPO" --ref "$TX_BRANCH" -f push=false
run=""
for _ in $(seq 1 30); do
  run="$(gh run list --repo "$TX_REPO" --workflow "$WORKFLOW" --branch "$TX_BRANCH" --event workflow_dispatch --limit 5 \
         --json databaseId,headSha,createdAt --jq "map(select(.headSha == \"$TX_NEW\" and .createdAt >= \"$since\")) | .[0].databaseId // empty")"
  [[ -n "$run" ]] && break; sleep 4
done
[[ -n "$run" ]] || die "dispatched run not found"
echo "run: https://github.com/$TX_REPO/actions/runs/$run"
gh run watch "$run" --repo "$TX_REPO" --interval 20 || true
gh run view "$run" --repo "$TX_REPO" --json url,status,conclusion,headSha,headBranch,event,jobs > "$EVIDENCE/run.json"
gh run view "$run" --repo "$TX_REPO" --log > "$EVIDENCE/run.log" 2>&1 || echo "log download incomplete" >> "$EVIDENCE/run.log"
ruby -rjson -e 'j = JSON.parse(File.read(ARGV[0]))
  puts "#{j["url"]}  #{j["status"]}/#{j["conclusion"]}  head=#{j["headSha"]} branch=#{j["headBranch"]} event=#{j["event"]}"
  j["jobs"].each { |x| puts "  #{x["conclusion"].to_s.ljust(9)} #{x["name"]}" }' "$EVIDENCE/run.json"
echo; echo "Evidence: $EVIDENCE   (run.json, run.log, tests.txt). Nothing was published or deployed."
