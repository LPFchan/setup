#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export SETUP_INSTALL_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/install.sh"
unset SETUP_INSTALL_SOURCE_ONLY

FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:/usr/bin:/bin"

uname() { echo Darwin; }
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "fzf" ]]; then
        builtin command -v "$FAKE_BIN/fzf"
    else
        builtin command "$@"
    fi
}

install_homebrew() {
    touch "$TEST_TMP/homebrew-installed"
    cat > "$FAKE_BIN/brew" <<EOF
#!/usr/bin/env bash
case "\$1" in
    shellenv) printf 'export PATH=%q:\$PATH\\n' "$FAKE_BIN" ;;
    install)
        [[ "\$2" == fzf ]] || exit 1
        touch "$TEST_TMP/fzf-installed"
        printf '#!/usr/bin/env bash\\n' > "$FAKE_BIN/fzf"
        chmod +x "$FAKE_BIN/fzf"
        ;;
esac
EOF
    chmod +x "$FAKE_BIN/brew"
}

ensure_macos_bootstrap_dependencies
[[ -e "$TEST_TMP/homebrew-installed" ]] || { echo "Homebrew was not installed" >&2; exit 1; }
[[ -e "$TEST_TMP/fzf-installed" ]] || { echo "fzf was not installed" >&2; exit 1; }
command -v fzf >/dev/null || { echo "fzf was not available after bootstrap" >&2; exit 1; }

rm -f "$FAKE_BIN/fzf"
cat > "$FAKE_BIN/brew" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    shellenv) echo ':' ;;
    install) exit 23 ;;
esac
EOF
chmod +x "$FAKE_BIN/brew"

if ensure_macos_bootstrap_dependencies 2>/dev/null; then
    echo "bootstrap unexpectedly succeeded when brew install fzf failed" >&2
    exit 1
fi

echo "macOS bootstrap tests passed"
