#!/usr/bin/env zsh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# The installer must not carry a Homebrew or stock-fzf UI dependency anymore.
if grep -Eq 'ensure_macos_bootstrap_dependencies|install_homebrew|brew.*install fzf' "$ROOT/install.sh"; then
    echo "installer still bootstraps Homebrew/stock fzf for setup UI" >&2
    exit 1
fi

# Source-only loading must work with a PATH that has neither brew nor fzf.
export HOME="$TEST_TMP/home"
export PATH="/usr/bin:/bin"
export SETUP_INSTALL_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/install.sh"
unset SETUP_INSTALL_SOURCE_ONLY

command -v configure_shell >/dev/null || {
    echo "installer helpers did not load without Homebrew/fzf" >&2
    exit 1
}

echo "macOS bootstrap tests passed"
