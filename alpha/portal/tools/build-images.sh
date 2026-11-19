#!/usr/bin/env bash
# Local, reproducible build of the 8 BE-293 Portal backend images from a pinned commit.
#
# - Builds from a clean `git archive` export of the pinned commit (never the working copy).
# - Default is a dry run that only prints the commands. `--execute` builds and loads images into the local
#   Docker daemon with a clearly non-deployable tag. There is deliberately NO push option: pushing to a
#   registry is a separately approved step.
# - After building, verifies that the migrations image contains both BE-293 migrations.
#
# Requirements for --execute: Docker daemon with buildx, network access to mcr.microsoft.com and
# api.nuget.org, and a local clone of ARENA2036/portal-backend containing the pinned commit.
#
# Usage: alpha/portal/tools/build-images.sh [--execute] [--source /path/to/portal-backend]
set -euo pipefail

COMMIT="f5badda90030531434c9445e5bb4b70382bea6eb"
SHORT="${COMMIT:0:9}"
LOCAL_TAG="be293-${SHORT}-LOCAL-NOT-FOR-DEPLOY"
PLATFORM="linux/amd64"
SOURCE="${PORTAL_BACKEND_SOURCE:-$HOME/Projects/ARENA2036/portal-backend}"
EXECUTE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=1; shift ;;
    --source) SOURCE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# image name : Dockerfile suffix
IMAGES=(
  "portal-administration-service:administration-service"
  "portal-registration-service:registration-service"
  "portal-marketplace-app-service:marketplace-app-service"
  "portal-services-service:services-service"
  "portal-notification-service:notification-service"
  "portal-maintenance-service:maintenance-service"
  "portal-processes-worker:processes-worker"
  "portal-migrations:portal-migrations"
)
MIGRATIONS=(20260710175010_BE293IdentityHubWalletStepTypes 20261024150921_BE293ConnectorProvisioningRequests)

run() {
  printf '+ %s\n' "$*"
  if [[ "$EXECUTE" == "1" ]]; then "$@"; fi
}

git -C "$SOURCE" cat-file -e "${COMMIT}^{commit}" 2>/dev/null || { echo "commit $COMMIT not found in $SOURCE" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-portal-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git -C "$SOURCE" archive "$COMMIT" | tar -x -C "$WORK"
echo "exported $COMMIT to $WORK ($(find "$WORK" -type f | wc -l | tr -d ' ') files)"

if [[ "$EXECUTE" == "1" ]]; then
  docker info >/dev/null 2>&1 || { echo "Docker daemon not reachable" >&2; exit 3; }
  docker buildx version >/dev/null 2>&1 || { echo "docker buildx not available" >&2; exit 3; }
fi

failed=0
for entry in "${IMAGES[@]}"; do
  image="${entry%%:*}"; dockerfile="docker/Dockerfile-${entry#*:}"
  ref="be293-local/${image}:${LOCAL_TAG}"
  if ! run docker buildx build --platform "$PLATFORM" --pull \
        --label "org.opencontainers.image.revision=${COMMIT}" \
        --label "org.opencontainers.image.source=https://github.com/ARENA2036/portal-backend" \
        -f "$WORK/$dockerfile" -t "$ref" --load "$WORK"; then
    echo "BUILD FAILED: $image" >&2; failed=1
  fi
done

# The migrations image must contain both BE-293 migrations (class names are embedded in the assembly).
mig_ref="be293-local/portal-migrations:${LOCAL_TAG}"
for m in "${MIGRATIONS[@]}"; do
  # Dockerfile-portal-migrations: WORKDIR /migrations, ENTRYPOINT dotnet <this assembly>.
  if ! run docker run --rm --network none --entrypoint /bin/sh "$mig_ref" -c "grep -a -q '$m' /migrations/Org.Eclipse.TractusX.Portal.Backend.PortalBackend.Migrations.dll"; then
    echo "MIGRATION MISSING: $m" >&2; failed=1
  fi
done

if [[ "$EXECUTE" == "1" ]]; then
  echo "local image IDs (not registry digests):"
  for entry in "${IMAGES[@]}"; do
    docker image inspect --format '{{.Id}}  {{index .RepoTags 0}}' "be293-local/${entry%%:*}:${LOCAL_TAG}" || failed=1
  done
fi

exit "$failed"
