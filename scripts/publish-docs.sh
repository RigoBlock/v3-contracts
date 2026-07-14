#!/usr/bin/env bash
# Publishes generated Solidity API docs to the GitBook-synced RigoBlock/v3-docs repo.
#
# Environment variables:
#   V3_DOCS_DIR         Local path where v3-docs is cloned (default: ../v3-docs)
#   V3_DOCS_REPO        Git URL of the v3-docs repo
#                       (default: https://github.com/RigoBlock/v3-docs.git)
#   V3_DOCS_BRANCH      Target branch in v3-docs (default: main)
#   TARGET_DIR          Directory inside v3-docs where API docs are copied
#                       (default: contracts/api)
#   DOCS_COMMIT_MESSAGE Commit message for the docs update
#                       (default: "chore: update Solidity API docs")
#   DRY_RUN             Set to any value to skip the final push

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

V3_DOCS_DIR="${V3_DOCS_DIR:-$REPO_ROOT/../v3-docs}"
V3_DOCS_REPO="${V3_DOCS_REPO:-https://github.com/RigoBlock/v3-docs.git}"
V3_DOCS_BRANCH="${V3_DOCS_BRANCH:-main}"
TARGET_DIR="${TARGET_DIR:-contracts/api}"
DOCS_COMMIT_MESSAGE="${DOCS_COMMIT_MESSAGE:-chore: update Solidity API docs}"

cd "$REPO_ROOT"

# 1. Generate docs
echo "Generating API docs..."
yarn docgen

# 2. Clone or update v3-docs
if [ -d "$V3_DOCS_DIR/.git" ]; then
  echo "Updating existing v3-docs clone..."
  cd "$V3_DOCS_DIR"
  git fetch origin "$V3_DOCS_BRANCH"
  git checkout "$V3_DOCS_BRANCH"
  git pull origin "$V3_DOCS_BRANCH"
else
  echo "Cloning v3-docs..."
  rm -rf "$V3_DOCS_DIR"
  git clone --depth 1 --branch "$V3_DOCS_BRANCH" "$V3_DOCS_REPO" "$V3_DOCS_DIR"
  cd "$V3_DOCS_DIR"
fi

# 3. Copy generated docs into v3-docs
FULL_TARGET_DIR="$V3_DOCS_DIR/$TARGET_DIR"
echo "Copying generated docs to $TARGET_DIR..."
rm -rf "$FULL_TARGET_DIR"
mkdir -p "$FULL_TARGET_DIR"
cp -R "$REPO_ROOT/docs/api/." "$FULL_TARGET_DIR/"

# 4. Update SUMMARY.md
SUMMARY_PATH="$V3_DOCS_DIR/SUMMARY.md"
echo "Updating $SUMMARY_PATH..."
node "$REPO_ROOT/scripts/generate-summary.js" "$TARGET_DIR" "$SUMMARY_PATH"

# 5. Commit and push
cd "$V3_DOCS_DIR"
git add -A
if git diff --cached --quiet; then
  echo "No changes to publish."
  exit 0
fi

git commit -m "$DOCS_COMMIT_MESSAGE"

if [ -n "${DRY_RUN:-}" ]; then
  echo "Dry run: not pushing."
  echo "Changes committed locally in $V3_DOCS_DIR"
else
  git push origin "$V3_DOCS_BRANCH"
  echo "Published docs to $V3_DOCS_REPO ($V3_DOCS_BRANCH)"
fi
