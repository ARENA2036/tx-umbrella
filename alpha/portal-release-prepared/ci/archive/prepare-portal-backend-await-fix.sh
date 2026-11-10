#!/usr/bin/env bash
# Prepare the BE-293 IdentityHub credential-await checklist fix commit locally (no push):
#   - new worktree + branch from the admin fix commit 274096a9 (the existing checkouts and worktrees are not touched)
#   - git apply --check, then apply portal-backend-identityhub-await-checklist-failed.patch; exactly its 4 files
#   - confirm both terminal branches now set the checklist entry FAILED
#   - Release-publish Processes.Worker (as docker/Dockerfile-processes-worker does)
#   - native dotnet test: IdentityHub.Library, ApplicationChecklist.Executor, ApplicationChecklist.Library,
#     IssuerComponent.Library, Administration.Service (its 4 Testcontainers integration tests run only with Docker)
#   - commit (author from your git config) and print the new SHA
# Requires: git, .NET SDK 9, network access to api.nuget.org. Stops on the first failure.
set -euo pipefail

BASE=274096a965c10d65a96d8c077a60b7680176aff7
BRANCH=fix/BE-293-identityhub-await-checklist-failed
SRC="${PORTAL_BACKEND_REPO:-$HOME/Projects/ARENA2036/portal-backend}"
WT="${PORTAL_BACKEND_AWAIT_WORKTREE:-$HOME/Projects/ARENA2036/portal-backend-await-fix}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/portal-backend-identityhub-await-checklist-failed.patch"
LOGIC=src/externalsystems/IdentityHub.Library/BusinessLogic/IdentityHubCredentialAwaitBusinessLogic.cs
EXPECTED_FILES="src/externalsystems/IdentityHub.Library/BusinessLogic/IIdentityHubCredentialAwaitBusinessLogic.cs
$LOGIC
tests/externalsystems/IdentityHub.Library.Tests/IdentityHubCredentialAwaitBusinessLogicTests.cs
tests/processes/ApplicationChecklist.Executor.Tests/ApplicationChecklistProcessTypeExecutorTests.cs"

git -C "$SRC" cat-file -e "${BASE}^{commit}" || { echo "$BASE not in $SRC (fetch the admin fix branch first)" >&2; exit 1; }
if git -C "$SRC" show-ref --verify -q "refs/heads/$BRANCH"; then echo "branch $BRANCH already exists" >&2; exit 1; fi
[[ ! -e "$WT" ]] || { echo "$WT already exists" >&2; exit 1; }
git -C "$SRC" worktree add -b "$BRANCH" "$WT" "$BASE"
cd "$WT"

git apply --check "$PATCH"
git apply --index "$PATCH"
test "$(git diff --cached --name-only | sort)" = "$(sort <<<"$EXPECTED_FILES")" || { echo "patch touched unexpected files" >&2; exit 1; }
test "$(grep -c 'return Fail(retriggerStepTypeId' "$LOGIC")" = 2 || { echo "expected both terminal branches to use Fail()" >&2; exit 1; }
grep -q 'entry.ApplicationChecklistEntryStatusId = ApplicationChecklistEntryStatusId.FAILED;' "$LOGIC"
echo "applied $(basename "$PATCH"): holder ERROR and deadline now set the checklist entry FAILED"

dotnet publish src/processes/Processes.Worker/Processes.Worker.csproj -c Release -o "$WT/.be293-publish" --nologo -v q
rm -rf "$WT/.be293-publish"

dotnet test tests/externalsystems/IdentityHub.Library.Tests --nologo -v q
dotnet test tests/processes/ApplicationChecklist.Executor.Tests --nologo -v q
dotnet test tests/processes/ApplicationChecklist.Library.Tests --nologo -v q
dotnet test tests/externalsystems/IssuerComponent.Library.Tests --nologo -v q
if docker info >/dev/null 2>&1; then
  dotnet test tests/administration/Administration.Service.Tests --nologo -v q
else
  echo "Docker not available: skipping the 4 Testcontainers integration tests of Administration.Service.Tests"
  dotnet test tests/administration/Administration.Service.Tests --nologo -v q \
    --filter 'FullyQualifiedName!~ConnectorsControllerIntegrationTests&FullyQualifiedName!~PublicUrl'
fi

git commit -q -F - <<'EOF'
fix(BE-293): fail the credential checklist entry when the IdentityHub await fails

AWAIT_BPN_CREDENTIAL_RESPONSE and AWAIT_MEMBERSHIP_CREDENTIAL_RESPONSE failed
the step (holder ERROR or wait deadline) and scheduled the retrigger, but
returned no checklist modification. BPNL_CREDENTIAL / MEMBERSHIP_CREDENTIAL
stayed IN_PROGRESS, and the manual retrigger, which requires FAILED,
answered 409.

Set the entry FAILED with a non-sensitive comment in both terminal
branches, as HandleServiceErrorAsync does. Retrigger scheduling, ISSUED,
pending and the deadline are unchanged. Regression tests cover both
credentials, terminal failure, timeout, issued, pending, executor
persistence and the callback/retrigger validation gates.

Only the processes-worker runs these handlers. Applications already in the
mismatch state are not repaired by this change.

EOF
echo "NEW_SHA=$(git rev-parse HEAD)"
git log -1 --format='%an <%ae> | %s'
git diff --stat "$BASE" HEAD
