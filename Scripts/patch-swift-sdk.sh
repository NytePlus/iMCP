#!/bin/bash
# Reproducible compatibility fix for the pinned MCP SDK. Preserve JSON values
# rather than discarding extension capabilities at the transport boundary.
set -euo pipefail
cd "$(dirname "$0")/.."
sdk=.sourcePackages/checkouts/swift-sdk
expected=6132fd4b5b4217ce4717c4775e4607f5c3120129
if [[ "$(git -C "$sdk" rev-parse HEAD)" != "$expected" ]]; then
  echo 'MCP SDK revision changed: review the experimental-capability patch before building.' >&2
  exit 1
fi
patch_file="$(pwd)/Scripts/Patches/swift-sdk-experimental-json.patch"
if git -C "$sdk" apply --reverse --check "$patch_file" 2>/dev/null; then
  exit 0
fi
git -C "$sdk" apply --check "$patch_file"
git -C "$sdk" apply "$patch_file"
