#!/bin/bash
# process-monitor: shared validated SSH transport.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/transport.sh"
ops_main process-monitor "$@"
