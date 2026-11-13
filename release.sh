#!/bin/zsh
# Publishes a new version: bump VERSION first, then run ./release.sh "what changed".
# Builds the app, zips it and creates the GitHub release that the in-app updater reads.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION)
NOTES=${1:-"ePerformance View $VERSION"}
./build.sh
ZIP="build/ePerformanceView.zip"   # stable name, so .../releases/latest/download/ePerformanceView.zip always works
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "build/ePerformance View.app" "$ZIP"
gh release create "v$VERSION" "$ZIP" --title "ePerformance View $VERSION" --notes "$NOTES"
