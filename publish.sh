#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

VERSION="$1"

# 1. Make sure everything is committed and nothing is staged
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: You have uncommitted or staged changes."
  echo "Please commit or stash everything before publishing."
  exit 1
fi

# 2. Update version in mix.exs (adjust the pattern if needed)
if [[ ! -f mix.exs ]]; then
  echo "Error: mix.exs not found. Run this from the project root."
  exit 1
fi

# Common pattern: version: "0.2.4"
sed -i '' -E "s/(version: \")([0-9]+\.[0-9]+\.[0-9]+)(\"[,}])/\\1${VERSION}\\3/" mix.exs

# If you use @version "0.2.4" instead, uncomment this:
# sed -i '' -E "s/(@version \")([0-9]+\.[0-9]+\.[0-9]+)(\")/\\1${VERSION}\\3/" mix.exs

git add mix.exs
git commit --amend --no-edit

# 3. Tag the commit with the version
git tag -a "$VERSION" -m "Release $VERSION"

# 4. Build and publish to Hex
mix hex.build
mix hex.publish
