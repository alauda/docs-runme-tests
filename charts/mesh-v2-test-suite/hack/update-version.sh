#!/usr/bin/env bash

# ============================================================================
# Description:
#   Update the chart version of mesh-v2-test-suite in two files at once:
#     - charts/mesh-v2-test-suite/Chart.yaml          (top-level `version:`)
#     - charts/mesh-v2-test-suite/module-plugin.yaml  (`spec.appReleases[0].chartVersions[0].version`)
#
#   Cross-platform: works with both GNU sed (Linux) and BSD sed (macOS).
#
# Usage:
#   ./hack/update-version.sh <NEW_VERSION>
#
# Example:
#   ./hack/update-version.sh v1.0.0-rc.2
#   ./hack/update-version.sh v1.0.0
# ============================================================================

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Error: Incorrect number of arguments." >&2
    echo "Usage: $0 <NEW_VERSION>" >&2
    exit 1
fi

NEW_VERSION="$1"

# Locate the chart root (parent directory of this script's hack/ folder).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHART_FILE="$CHART_ROOT/Chart.yaml"
MODULE_PLUGIN_FILE="$CHART_ROOT/module-plugin.yaml"

for f in "$CHART_FILE" "$MODULE_PLUGIN_FILE"; do
    if [ ! -f "$f" ]; then
        echo "Error: file not found: $f" >&2
        exit 1
    fi
done

# Cross-platform in-place sed: BSD sed on macOS requires an explicit empty backup suffix.
sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# Escape characters that have special meaning in the replacement side of `s/.../.../`
# (`/`, `&`, `\`). The version string is treated as a literal.
ESCAPED_NEW_VERSION=$(printf '%s' "$NEW_VERSION" | sed -e 's/[\/&]/\\&/g')

# Chart.yaml: top-level `version:` (no leading whitespace).
sed_inplace -E "s/^version: .*/version: ${ESCAPED_NEW_VERSION}/" "$CHART_FILE"

# module-plugin.yaml: the `version:` under chartVersions[0] (6-space indent).
sed_inplace -E "s/^      version: .*/      version: ${ESCAPED_NEW_VERSION}/" "$MODULE_PLUGIN_FILE"

echo "Updated chart version to: ${NEW_VERSION}"
echo "  - ${CHART_FILE}"
echo "  - ${MODULE_PLUGIN_FILE}"
