#!/bin/bash
#
# Custom Moderne CLI wrapper script (Linux / macOS)
# Handles initialization (mod config commands).
# Delegates actual CLI execution to modw.
#
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$SCRIPT_DIR/modw"

# ---------------------------------------------------------------------------
# Initialization — runs once to configure the CLI environment
# ---------------------------------------------------------------------------
init() {
    echo "Configuring Moderne CLI environment..." >&2

    # 1. Sync license from the Moderne platform
    "$MOD" config license moderne sync

    # 2. Sync recipes from the Moderne platform
    "$MOD" config recipes moderne sync

    # 3. Disallow Maven Central for recipe/artifact resolution
    "$MOD" config features no-maven-central

    # 4. Install a corporate CA certificate into the Java trust store
    #    Adjust the path to your actual certificate file.
    "$MOD" config http trust-store edit file --path "$SCRIPT_DIR/certs/corporate-ca.pem"

    echo -e "${GREEN}CLI environment configured successfully.${NC}" >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    if [[ "${1:-}" == "init" ]]; then
        init
        exit 0
    fi

    if [[ $# -eq 0 ]]; then
        echo -e "${RED}Usage: $0 init        — configure the CLI environment${NC}" >&2
        echo -e "${RED}       $0 <command>   — run a mod CLI command${NC}" >&2
        exit 1
    fi

    "$MOD" "$@"
}

main "$@"
