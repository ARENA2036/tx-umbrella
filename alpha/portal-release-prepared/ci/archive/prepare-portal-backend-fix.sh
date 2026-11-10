#!/usr/bin/env bash
# Prepare the BE-293 portal-backend fix commit locally (no push):
#   - new worktree + branch from the pinned BE-293 commit (the existing checkout is not touched)
#   - apply portal-backend-maintenance-dockerfile.patch and portal-backend-pkcs-cve-2026-84008.patch
#   - restore, verify System.Security.Cryptography.Pkcs resolves to 8.0.2 for Processes.Worker,
#     build the 8 image projects, run the mailing/processes tests
#   - commit (author from your git config, no extra trailers) and print the new SHA
# Requires: git, .NET SDK 9, network access to api.nuget.org. Stops on the first failure.
set -euo pipefail

BASE=f5badda90030531434c9445e5bb4b70382bea6eb
BRANCH=fix/be293-portal-worker-pkcs-maintenance
SRC="${PORTAL_BACKEND_REPO:-$HOME/Projects/ARENA2036/portal-backend}"
WT="${PORTAL_BACKEND_FIX_WORKTREE:-$HOME/Projects/ARENA2036/portal-backend-be293-fix}"
PATCHES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git -C "$SRC" cat-file -e "${BASE}^{commit}"
if git -C "$SRC" show-ref --verify -q "refs/heads/$BRANCH"; then echo "branch $BRANCH already exists" >&2; exit 1; fi
[[ ! -e "$WT" ]] || { echo "$WT already exists" >&2; exit 1; }
git -C "$SRC" worktree add -b "$BRANCH" "$WT" "$BASE"
cd "$WT"

for p in portal-backend-maintenance-dockerfile.patch portal-backend-pkcs-cve-2026-84008.patch; do
  sed -n '/^--- a\//,$p' "$PATCHES/$p" > "$WT/.be293.patch"
  git apply --check "$WT/.be293.patch"
  git apply "$WT/.be293.patch"
  rm -f "$WT/.be293.patch"
  echo "applied $p"
done
test "$(git diff --name-only | sort | tr '\n' ' ')" = "docker/Dockerfile-maintenance-service src/mailing/Mailing.SendMail/Mailing.SendMail.csproj "

dotnet restore src/processes/Processes.Worker/Processes.Worker.csproj
pkcs="$(dotnet list src/processes/Processes.Worker/Processes.Worker.csproj package --include-transitive | grep -i 'System.Security.Cryptography.Pkcs' || true)"
echo "$pkcs"
grep -q '8\.0\.2' <<<"$pkcs" || { echo "Pkcs did not resolve to 8.0.2" >&2; exit 1; }
if grep -q '8\.0\.1' <<<"$pkcs"; then echo "Pkcs 8.0.1 still resolved" >&2; exit 1; fi

for proj in \
  src/administration/Administration.Service/Administration.Service.csproj \
  src/registration/Registration.Service/Registration.Service.csproj \
  src/marketplace/Apps.Service/Apps.Service.csproj \
  src/marketplace/Services.Service/Services.Service.csproj \
  src/notifications/Notifications.Service/Notifications.Service.csproj \
  src/maintenance/Maintenance.App/Maintenance.App.csproj \
  src/processes/Processes.Worker/Processes.Worker.csproj \
  src/portalbackend/PortalBackend.Migrations/PortalBackend.Migrations.csproj; do
  dotnet build "$proj" -c Release --nologo -v q
done
dotnet test tests/processes/Mailing.Executor.Tests --nologo -v q
dotnet test tests/processes/ApplicationChecklist.Executor.Tests --nologo -v q

git add docker/Dockerfile-maintenance-service src/mailing/Mailing.SendMail/Mailing.SendMail.csproj
git commit -q -F - <<'EOF'
fix(BE-293): maintenance image build input and Pkcs CVE-2026-84008

- docker/Dockerfile-maintenance-service: copy src/onboarding/Onboarding.WalletProvider,
  referenced by ApplicationChecklist.Library since BE-293; dotnet publish of
  Maintenance.App failed with CS0234/CS0246 (IWalletProviderResolver).
- Mailing.SendMail: pin System.Security.Cryptography.Pkcs to 8.0.2. MimeKit 4.13.0
  resolved 8.0.1 (Trivy HIGH CVE-2026-84008, fixed in 8.0.2) in the processes-worker
  image; MimeKit's >= 8.0.1 constraint stays satisfied.

No functional change; BE-293 migrations and onboarding integrations are unchanged.
EOF
echo "NEW_SHA=$(git rev-parse HEAD)"
git log -1 --format='%an <%ae> | %s'
git diff --stat "$BASE" HEAD
