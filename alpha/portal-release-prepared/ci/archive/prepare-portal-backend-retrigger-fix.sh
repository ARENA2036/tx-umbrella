#!/usr/bin/env bash
# Prepare the BE-293 RETRIGGER_VALIDATE_DID_DOCUMENT fix commit locally (no push):
#   - new worktree + branch from the commit deployed on Alpha (images.lock source.commit; the existing
#     checkouts and the fix/be293-portal-worker-pkcs-maintenance worktree are not touched)
#   - git apply --check, then apply portal-backend-retrigger-validate-did.patch; exactly its 4 files may change
#   - confirm the mapping now resumes IDENTITY_WALLET in IN_PROGRESS
#   - Release-publish Administration.Service (as docker/Dockerfile-administration-service does)
#   - native dotnet test: ApplicationChecklist.Library, BpnDidResolver.Library, ApplicationChecklist.Executor,
#     Administration.Service (its 4 Testcontainers integration tests run only when Docker is available)
#   - commit (author from your git config) and print the new SHA
# Requires: git, .NET SDK 9, network access to api.nuget.org. Stops on the first failure.
set -euo pipefail

BASE=ad459ee711ecaa9a43535a513bd9db83b640a8ff
BRANCH=fix/BE-293-retrigger-validate-did-in-progress
SRC="${PORTAL_BACKEND_REPO:-$HOME/Projects/ARENA2036/portal-backend}"
WT="${PORTAL_BACKEND_RETRIGGER_WORKTREE:-$HOME/Projects/ARENA2036/portal-backend-retrigger-fix}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/portal-backend-retrigger-validate-did.patch"
MAPPING=src/processes/ApplicationChecklist.Library/ApplicationChecklistEntryTypeIdExtensions.cs
EXPECTED_FILES="$MAPPING
tests/administration/Administration.Service.Tests/BusinessLogic/RegistrationBusinessLogicTest.cs
tests/externalsystems/BpnDidResolver.Library.Tests/DidDocumentValidationBusinessLogicTests.cs
tests/processes/ApplicationChecklist.Library.Tests/ApplicationChecklistEntryTypeIdExtensionsTests.cs"

lock_commit="$(sed -n 's/^  commit: *\([0-9a-f]\{40\}\).*/\1/p' "$HERE/../images.lock.yaml")"
[[ "$lock_commit" == "$BASE" ]] || { echo "images.lock source.commit $lock_commit != $BASE (re-check the deployed baseline)" >&2; exit 1; }
git -C "$SRC" cat-file -e "${BASE}^{commit}"
if git -C "$SRC" show-ref --verify -q "refs/heads/$BRANCH"; then echo "branch $BRANCH already exists" >&2; exit 1; fi
[[ ! -e "$WT" ]] || { echo "$WT already exists" >&2; exit 1; }
git -C "$SRC" worktree add -b "$BRANCH" "$WT" "$BASE"
cd "$WT"

git apply --check "$PATCH"
git apply --index "$PATCH"
test "$(git diff --cached --name-only | sort)" = "$(sort <<<"$EXPECTED_FILES")" || { echo "patch touched unexpected files" >&2; exit 1; }
grep -q 'RETRIGGER_VALIDATE_DID_DOCUMENT => (ProcessStepTypeId.VALIDATE_DID_DOCUMENT, ApplicationChecklistEntryStatusId.IN_PROGRESS)' "$MAPPING"
! grep -q 'RETRIGGER_VALIDATE_DID_DOCUMENT => (ProcessStepTypeId.VALIDATE_DID_DOCUMENT, ApplicationChecklistEntryStatusId.TO_DO)' "$MAPPING"
echo "applied $(basename "$PATCH"): RETRIGGER_VALIDATE_DID_DOCUMENT -> VALIDATE_DID_DOCUMENT, IDENTITY_WALLET IN_PROGRESS"

dotnet publish src/administration/Administration.Service/Administration.Service.csproj -c Release -o "$WT/.be293-publish" --nologo -v q
rm -rf "$WT/.be293-publish"

dotnet test tests/processes/ApplicationChecklist.Library.Tests --nologo -v q
dotnet test tests/externalsystems/BpnDidResolver.Library.Tests --nologo -v q
dotnet test tests/processes/ApplicationChecklist.Executor.Tests --nologo -v q
if docker info >/dev/null 2>&1; then
  dotnet test tests/administration/Administration.Service.Tests --nologo -v q
else
  echo "Docker not available: skipping the 4 Testcontainers integration tests of Administration.Service.Tests"
  dotnet test tests/administration/Administration.Service.Tests --nologo -v q \
    --filter 'FullyQualifiedName!~ConnectorsControllerIntegrationTests&FullyQualifiedName!~PublicUrl'
fi

git commit -q -F - <<'EOF'
fix(BE-293): resume IDENTITY_WALLET in IN_PROGRESS on DID validation retrigger

RETRIGGER_VALIDATE_DID_DOCUMENT set the IDENTITY_WALLET checklist entry to
TO_DO, but VALIDATE_DID_DOCUMENT only runs while that entry is IN_PROGRESS
(the state wallet creation leaves it in). The retriggered step therefore
failed at once, scheduled no further retrigger, and left the application
unrecoverable through the retrigger-validate-did endpoint.

Map the retrigger to IN_PROGRESS, as RETRIGGER_BUSINESS_PARTNER_NUMBER_PULL
and the activation retriggers already do. The retrigger schedules only
VALIDATE_DID_DOCUMENT; the wallet is never recreated. Regression tests cover
the 403 failure -> manual retrigger -> successful validation path.

Only Administration.Service reads this mapping.
EOF
echo "NEW_SHA=$(git rev-parse HEAD)"
git log -1 --format='%an <%ae> | %s'
git diff --stat "$BASE" HEAD
