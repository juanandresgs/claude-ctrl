#!/usr/bin/env bash
set -euo pipefail

# Shared bootstrap loader.
# Current bootstrap still uses the imported v2 hook helpers. This file is the
# future stable import point for decomposed hook entrypoints.

HOOK_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_ROOT=$(cd "$HOOK_LIB_DIR/.." && pwd)

source "$HOOK_ROOT/log.sh"
source "$HOOK_ROOT/context-lib.sh"
source "$HOOK_LIB_DIR/runtime-bridge.sh"
