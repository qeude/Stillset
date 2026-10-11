#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: update_homebrew_release.sh VERSION CHECKSUM_FILE}"
CHECKSUM_FILE="${2:?missing checksum file}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
SHA256="$(cut -d ' ' -f 1 "$CHECKSUM_FILE")"
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 1
[[ "$(< "$CHECKSUM_FILE")" == "$SHA256  Stillset-v$VERSION.zip" ]] || exit 1
: "${GH_TOKEN:?Set HOMEBREW_TAP_TOKEN with contents and pull-requests write access to qeude/homebrew-tap}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO=qeude/homebrew-tap
CASK=Casks/stillset.rb
BRANCH="release/stillset-$VERSION"
BASE_SHA="$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)"
if ! gh api "repos/$REPO/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  gh api "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$BASE_SHA" >/dev/null
fi
CONTENT="$(sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA256/" "$ROOT_DIR/packaging/homebrew/stillset.rb" | base64 | tr -d '\n')"
FILE_SHA=""
if gh api "repos/$REPO/contents/$CASK?ref=$BRANCH" >/dev/null 2>&1; then
  FILE_SHA="$(gh api "repos/$REPO/contents/$CASK?ref=$BRANCH" --jq .sha)"
fi
gh api --method PUT "repos/$REPO/contents/$CASK" \
  -f message="chore: update Stillset to $VERSION" -f branch="$BRANCH" \
  -f content="$CONTENT" ${FILE_SHA:+-f sha="$FILE_SHA"} >/dev/null
if [[ "$(gh pr list --repo "$REPO" --head "$BRANCH" --json number --jq length)" == 0 ]]; then
  gh pr create --repo "$REPO" --base main --head "$BRANCH" \
    --title "chore: update Stillset to $VERSION" \
    --body "Update to https://github.com/qeude/Stillset/releases/tag/v$VERSION. SHA-256: $SHA256."
fi
