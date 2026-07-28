#!/bin/bash
# Shared helpers for the pool-*.sh scripts. Sourced, not run directly.
#
#   BASEDIR   absolute path to this repo (works from any cwd)
#   PM2       path to pm2, or empty if not installed
#   PM2_NAME  pm2 process name used for the pool
#   have_pm2 / pool_instances / require_node12

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM2_NAME="bitqube-pool"

# Load nvm and select Node 12. The vendored stratum-pool's native deps (bignum)
# and the pinned winston stack only work on Node 12.x.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
command -v nvm >/dev/null 2>&1 && nvm use 12 >/dev/null 2>&1

PM2="$(command -v pm2 || true)"

have_pm2() { [ -n "$PM2" ]; }

require_node12() {
    if ! command -v node >/dev/null 2>&1; then
        echo "ERROR: node not found. Run: nvm install 12 && nvm use 12" >&2
        return 1
    fi
    local major
    major="$(node -v | sed 's/^v\([0-9]*\).*/\1/')"
    if [ "$major" != "12" ]; then
        echo "ERROR: Node $(node -v) detected — this pool requires Node 12.x." >&2
        echo "       Newer Node breaks the vendored stratum-pool (bignum, winston)." >&2
        echo "       Run: nvm install 12 && nvm use 12" >&2
        return 1
    fi
    return 0
}

# Number of running `node init.js` processes. MUST be 1 while the pool is up —
# two instances double-append to the global statHistory zset and exhaust RAM.
pool_instances() {
    pgrep -fc "node .*init\.js" 2>/dev/null || echo 0
}
