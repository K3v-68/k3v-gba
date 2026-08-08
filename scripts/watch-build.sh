#!/usr/bin/env bash
set -euo pipefail

BRANCH=$(git rev-parse --abbrev-ref HEAD)
SAFE_BRANCH=$(printf '%s' "$BRANCH" | sed 's#[^A-Za-z0-9._-]#-#g')
PACKAGE_ARTIFACT="package-$SAFE_BRANCH"

echo "Finding latest build run on branch '$BRANCH'..."
RUN_ID=$(gh run list --workflow=build-branch.yml --branch="$BRANCH" --limit=1 --json databaseId --jq '.[0].databaseId')

if [ -z "$RUN_ID" ]; then
  echo "No workflow runs found for branch '$BRANCH'."
  exit 1
fi

echo "Watching run $RUN_ID..."
gh run watch "$RUN_ID"

STATUS=$(gh run view "$RUN_ID" --json conclusion --jq '.conclusion')
if [ "$STATUS" != "success" ]; then
  echo "Build failed (status: $STATUS)."
  echo "Inspect the run with: gh run view $RUN_ID --log-failed"
  exit 1
fi

echo "Downloading package and reports..."
mkdir -p build_output
gh run download "$RUN_ID" -n "$PACKAGE_ARTIFACT" -D build_output/package
gh run download "$RUN_ID" -n reports -D build_output 2>/dev/null || true
gh run download "$RUN_ID" -n timing -D build_output 2>/dev/null || true

echo "Done! Package and provenance are in build_output/package/"
