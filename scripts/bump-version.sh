#!/bin/bash
# bump-version.sh — Semantic versioning for DigiFox
#
# Usage:
#   ./scripts/bump-version.sh patch   # 1.2.3 → 1.2.4
#   ./scripts/bump-version.sh minor   # 1.2.3 → 1.3.0
#   ./scripts/bump-version.sh major   # 1.2.3 → 2.0.0 (use manually!)
#
# Reads current version from Info.plist, bumps it, updates Info.plist,
# creates a git tag, and updates CHANGELOG.md header.

set -euo pipefail

PLIST="DigiFox/Info.plist"
BUMP_TYPE="${1:-}"

if [[ -z "$BUMP_TYPE" ]]; then
    echo "Usage: $0 {patch|minor|major}"
    echo "  major versions should be created manually!"
    exit 1
fi

if [[ ! -f "$PLIST" ]]; then
    echo "Error: $PLIST not found. Run from repo root."
    exit 1
fi

# Read current version
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
echo "Current version: $CURRENT"

# Parse semver
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case "$BUMP_TYPE" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    *)
        echo "Error: Unknown bump type '$BUMP_TYPE'. Use: patch, minor, or major"
        exit 1
        ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo "New version: $NEW_VERSION"

# Update Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"
echo "Updated $PLIST"

# Stage and commit
git add "$PLIST"
git commit -m "Bump version to $NEW_VERSION"

# Create git tag
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"
echo "Created tag v${NEW_VERSION}"

echo ""
echo "Done! Version bumped to $NEW_VERSION"
echo "Don't forget to: git push && git push --tags"
