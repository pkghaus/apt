#!/usr/bin/env bash
# Substitutes the pkghaus-stats D1 id into wrangler.toml. The file carries a
# placeholder so nothing can create a database by naming one that does not
# exist; every workflow that runs wrangler against it calls this first.
set -euo pipefail

id="$(npx wrangler d1 list --json | jq -r '.[] | select(.name == "pkghaus-stats") | .uuid')"
if [ -z "$id" ]; then
  echo "::error title=D1 database missing::pkghaus-stats does not exist in this account. Create it deliberately and restore from the newest Export D1 artifact in pkghaus/stats; do not let a deploy recreate it empty."
  exit 1
fi
sed -i "s/PLACEHOLDER_RESOLVED_IN_CI/$id/" wrangler.toml
