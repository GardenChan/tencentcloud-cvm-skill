#!/bin/bash
# Optional, reviewable network setup for a CVM purchase.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/ensure_network.py" "$@"
