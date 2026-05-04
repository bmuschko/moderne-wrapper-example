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
MODERNE_TENANT="https://moderne.mycompany.com"

# ---------------------------------------------------------------------------
# Initialization — runs once to configure the CLI environment
# ---------------------------------------------------------------------------
init() {
    echo "Configuring Moderne CLI environment..." >&2

    echo "Setting Moderne tenant to $MODERNE_TENANT..." >&2
    "$MOD" config moderne edit "$MODERNE_TENANT" --api="$MODERNE_TENANT"

    echo "Syncing license from Moderne platform..." >&2
    "$MOD" config license moderne sync

    echo "Disallowing Maven Central for artifact resolution..." >&2
    "$MOD" config features no-maven-central

    echo "Installing corporate CA certificate into Java trust store..." >&2
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
