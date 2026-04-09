#!/bin/bash
# rewrite-authors.sh — Rewrite all non-Gerolf commit authors
#
# Rewrites commits from Copilot, Claude, and you@example.com
# to Gerolf Ziegenhain <gerolf.ziegenhain@gmail.com>
#
# ⚠️  This rewrites git history! Requires force-push afterwards.

set -euo pipefail

GFR="/Users/gerolfziegenhain/Library/Python/3.9/bin/git-filter-repo"

echo "Creating mailmap for author rewrite..."

cat > /tmp/digifox-mailmap <<'EOF'
Gerolf Ziegenhain <gerolf.ziegenhain@gmail.com> <you@example.com>
Gerolf Ziegenhain <gerolf.ziegenhain@gmail.com> <noreply@anthropic.com>
Gerolf Ziegenhain <gerolf.ziegenhain@gmail.com> <198982749+Copilot@users.noreply.github.com>
Gerolf Ziegenhain <gerolf.ziegenhain@gmail.com> <gerolf.ziegenhain@dfs.de>
Gerolf Ziegenhain <gerolf.ziegenhain@gmail.com> copilot-swe-agent[bot] <198982749+Copilot@users.noreply.github.com>
Gerolf Ziegenhain <gerolf.ziegenhain@gmail.com> Claude <noreply@anthropic.com>
Gerolf Ziegenhain <gerolf.ziegenhain@gmail.com> Gerolf Ziegenhain <you@example.com>
Gerolf Ziegenhain <gerolf.ziegenhain@gmail.com> Dr. Gerolf Ziegenhain <gerolf.ziegenhain@dfs.de>
EOF

echo "Rewriting git history..."
"$GFR" --mailmap /tmp/digifox-mailmap --force

echo ""
echo "Done! Verify with: git log --format='%ae %an' | sort -u"
echo "Then force-push: git push --force-with-lease"

rm -f /tmp/digifox-mailmap
