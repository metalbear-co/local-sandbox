#!/usr/bin/env bash
set -euo pipefail

# Colima maps the `docker:` block in colima.yaml directly to daemon.json inside
# the VM. ~/.docker/daemon.json on the Mac is not used by Colima.
#
# Default BuildKit GC limits (~1-2 GiB) are too small for operator Docker builds;
# cache is pruned after a short idle gap and rebuilds look uncached.

COLIMA_YAML="${COLIMA_YAML:-$HOME/.colima/default/colima.yaml}"
KEEP_STORAGE="${BUILD_CACHE_KEEP_STORAGE:-30GB}"

if [ ! -f "$COLIMA_YAML" ]; then
  echo "Colima profile not found at $COLIMA_YAML"
  echo "Start Colima first: colima start"
  exit 1
fi

if grep -q 'defaultKeepStorage' "$COLIMA_YAML"; then
  echo "Colima BuildKit cache already configured in $COLIMA_YAML"
  grep -A3 'defaultKeepStorage' "$COLIMA_YAML" || true
  exit 0
fi

cp "$COLIMA_YAML" "${COLIMA_YAML}.bak.$(date +%Y%m%d%H%M%S)"

if grep -qE '^docker:[[:space:]]*\{\}[[:space:]]*$' "$COLIMA_YAML"; then
  perl -i -pe 'BEGIN { undef $/; } s/^docker:\s*\{\}\s*$/docker:\n  builder:\n    gc:\n      enabled: true\n      defaultKeepStorage: "'"$KEEP_STORAGE"'"/m' "$COLIMA_YAML"
else
  echo "docker: is not empty in $COLIMA_YAML; merge this block manually under docker:"
  cat <<EOF
  builder:
    gc:
      enabled: true
      defaultKeepStorage: "$KEEP_STORAGE"
EOF
  exit 1
fi

echo "Updated $COLIMA_YAML (backup saved alongside)."
echo "Restart Colima to apply: colima restart"
