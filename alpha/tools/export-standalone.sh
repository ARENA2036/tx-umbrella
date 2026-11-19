#!/usr/bin/env bash
# Export the repository's alpha/ folder as the standalone working folder (default ~/alpha), or check for drift.
#
#   bash alpha/tools/export-standalone.sh [DEST]           # export to DEST (default: ~/alpha)
#   bash alpha/tools/export-standalone.sh --check [DEST]   # export to a temp dir and require `diff -r` with DEST empty
#
# One layout: the export IS alpha/ (no file is rewritten), plus docs/ with two reference documents from docs/dev/.
# Content = files Git tracks or would track under alpha/ (tracked, staged, and new files that are not ignored). Never
# exported: ignored files (e.g. portal/.evidence/ live snapshots), .DS_Store, editor state (.claude/), and
# portal/ci/archive/ (one-off scripts against other checkouts). The repository is only read.
#
# Safety: DEST is replaced only if it is empty, or carries the export marker (.be293-standalone-export), or — once,
# with --adopt — already looks like an earlier hand-made copy (env.sh, portal/, identity/, charts/). Nothing else is
# ever deleted.
set -euo pipefail

ALPHA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ALPHA/.." && pwd)"
MARKER=".be293-standalone-export"
DOCS=(docs/dev/BE-293-phase7-preflight.md docs/dev/BE-293-alpha-portal-test-replica-roadmap-v5.md)

die() { echo "ABORT: $*" >&2; exit 1; }
usage() { echo "usage: export-standalone.sh [--check] [--adopt] [DEST]   (DEST defaults to ~/alpha)" >&2; exit 2; }

MODE=export; ADOPT=0; DEST=""
for a in "$@"; do
  case "$a" in
    --check) MODE=check ;;
    --adopt) ADOPT=1 ;;
    -*) usage ;;
    *) [[ -z "$DEST" ]] || usage; DEST="$a" ;;
  esac
done
DEST="${DEST:-$HOME/alpha}"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$REPO is not a Git checkout"
[[ "$(git -C "$REPO" rev-parse --show-toplevel)" == "$REPO" ]] || die "alpha/ is not at the top of the checkout"

# build_export DIR: write the export into the empty directory DIR
build_export() {
  local out="$1" list
  list="$(mktemp "${TMPDIR:-/tmp}/be293-export-list.XXXXXX")"
  git -C "$REPO" ls-files -z --cached --others --exclude-standard -- alpha \
    | tr '\0' '\n' \
    | grep -v -E '(^|/)\.DS_Store$|(^|/)\.claude/|^alpha/portal/ci/archive/' \
    | sed 's#^alpha/##' > "$list"
  while IFS= read -r f; do
    [[ -e "$ALPHA/$f" ]] || continue            # tracked but deleted in the working tree: not exported
    mkdir -p "$out/$(dirname "$f")"
    cp -p "$ALPHA/$f" "$out/$f"
  done < "$list"
  rm -f "$list"
  mkdir -p "$out/docs"
  for d in "${DOCS[@]}"; do cp -p "$REPO/$d" "$out/docs/$(basename "$d")"; done
  printf 'Standalone export of tx-umbrella alpha/ (alpha/tools/export-standalone.sh). Do not edit: change the repository and re-export.\n' > "$out/$MARKER"
  # The export must be self-contained: the gates need every pinned chart package.
  local missing=""
  for p in charts/umbrella-3.17.0/charts/portal-2.6.0.tgz charts/portal-2.6.0-patched/portal-2.6.0.tgz \
           charts/identity/vault-0.29.1.tgz charts/identity/postgresql-16.0.0.tgz charts/identity/bdrs-server-0.6.0.tgz \
           charts/identity/tractusx-issuerservice-v0.4.1.tgz charts/identity/tractusx-identityhub-v0.4.1.tgz \
           charts/identity/tractusx-connector-0.13.0.tgz; do
    [[ -f "$out/$p" ]] || missing+=" $p"
  done
  [[ -z "$missing" ]] || die "export lacks pinned chart packages (not tracked or staged?):$missing"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-export.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
build_export "$WORK/alpha"

if [[ "$MODE" == check ]]; then
  [[ -d "$DEST" ]] || die "$DEST does not exist"
  if diff -r "$WORK/alpha" "$DEST" > "$WORK/drift.txt"; then
    echo "OK   no drift: $DEST is identical to an export of $ALPHA"
    exit 0
  fi
  sed -e "s#$WORK/alpha#EXPORT#g" "$WORK/drift.txt" | grep -E '^(Only in|Files|diff)' | sed 's/^/DRIFT /' >&2
  echo "FAIL $DEST differs from an export of $ALPHA (re-run without --check to regenerate)" >&2
  exit 1
fi

# export: replace DEST only if it is safe to do so
if [[ -e "$DEST" ]]; then
  [[ -d "$DEST" ]] || die "$DEST exists and is not a directory"
  if [[ -z "$(ls -A "$DEST")" || -f "$DEST/$MARKER" ]]; then
    :
  elif [[ "$ADOPT" == 1 && -f "$DEST/env.sh" && -d "$DEST/portal" && -d "$DEST/identity" && -d "$DEST/charts" ]]; then
    echo "NOTE adopting the earlier hand-made copy in $DEST (no export marker yet)"
  else
    die "$DEST is not empty and has no $MARKER: refusing to replace it (use --adopt once for an earlier copy of alpha)"
  fi
  find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
mkdir -p "$DEST"
cp -Rp "$WORK/alpha/." "$DEST/"
echo "OK   exported $ALPHA to $DEST ($(find "$DEST" -type f | wc -l | tr -d ' ') files)"
