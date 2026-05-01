#!/bin/bash
#
# Custom Moderne CLI wrapper script (Linux / macOS)
# Handles initialization (mod config commands) and telemetry publishing.
# Delegates actual CLI execution to modw.
#
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
# Telemetry — publish CSV trace files to a BI endpoint after each command
# ---------------------------------------------------------------------------
publish_telemetry() {
    local command_name="$1"

    if [[ -z "${BI_ENDPOINT:-}" ]]; then
        return 0
    fi

    local telemetry_dir="${MODERNE_CLI_HOME:-$HOME/.moderne/cli}/trace"
    local search_dir="$telemetry_dir/$command_name"

    if [[ ! -d "$search_dir" ]]; then
        return 0
    fi

    local csv_files=()
    while IFS= read -r -d '' file; do
        csv_files+=("$file")
    done < <(find "$search_dir" -name "*.csv" -type f -print0 2>/dev/null)

    if [[ ${#csv_files[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Publishing telemetry data to $BI_ENDPOINT..." >&2

    for csv_file in "${csv_files[@]}"; do
        if [[ ! -f "$csv_file" ]]; then
            continue
        fi

        local parent_dir
        parent_dir="$(dirname "$csv_file")"
        local relative_path="${csv_file#"$(pwd)"/}"

        local curl_cmd=(curl -X POST -H "Content-Type: text/csv" --data-binary "@$csv_file")

        if [[ -n "${BI_AUTH_USER:-}" && -n "${BI_AUTH_PASS:-}" ]]; then
            curl_cmd+=(--user "$BI_AUTH_USER:$BI_AUTH_PASS")
        fi

        local proxy_url=""
        if [[ "$BI_ENDPOINT" == https://* && -n "${HTTPS_PROXY:-}" ]]; then
            proxy_url="$HTTPS_PROXY"
        elif [[ -n "${HTTP_PROXY:-}" ]]; then
            proxy_url="$HTTP_PROXY"
        fi

        if [[ -n "$proxy_url" ]]; then
            curl_cmd+=(--proxy "$proxy_url")
            if [[ -n "${PROXY_USER:-}" && -n "${PROXY_PASS:-}" ]]; then
                curl_cmd+=(--proxy-user "$PROXY_USER:$PROXY_PASS")
            fi
        fi

        curl_cmd+=("$BI_ENDPOINT" --silent --fail --show-error)

        if ERROR_MSG=$("${curl_cmd[@]}" 2>&1); then
            rm -rf "$parent_dir"
            echo -e "${GREEN}[OK] Published: $relative_path${NC}" >&2
        else
            echo -e "${YELLOW}[WARN] Failed to publish: $relative_path${NC}" >&2
            echo -e "${YELLOW}       Error: $ERROR_MSG${NC}" >&2
        fi
    done
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
        echo -e "${RED}       $0 <command>   — run a mod CLI command with telemetry${NC}" >&2
        exit 1
    fi

    local command_name="$1"

    "$MOD" "$@"
    CLI_EXIT_CODE=$?

    echo >&2

    publish_telemetry "$command_name"

    exit $CLI_EXIT_CODE
}

main "$@"
