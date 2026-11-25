#!/bin/bash
# scripts/mail-forward-policy/install.sh
# Installer module for HestiaCP Mail Forward Policy (blocks external forwards for non-admins)

set -euo pipefail

print_usage() {
    cat << 'EOF'
Usage: install.sh [OPTIONS]

Options:
  --allow-untested-hestia  Override the HestiaCP version pin for manual runs
  --apt-hook               Internal APT post-invoke mode (holds core PHP hooks on version mismatch)
  --help, -h               Show this help message
EOF
}

for arg in "$@"; do
    case "$arg" in
        --allow-untested-hestia) export ALLOW_UNTESTED_HESTIA=1 ;;
        --apt-hook)              export HESTIA_APT_HOOK=1 ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg" >&2
            print_usage >&2
            exit 1
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="$HESTIA/bin"
CONF_FILE="${MFP_CONF:-/etc/hestiacp-mail-forward-policy.conf}"
APT_CONF_DIR="${APT_CONF_DIR:-/etc/apt/apt.conf.d}"
export MFP_CONF="$CONF_FILE"

VERSION_GATE_LIB="$SCRIPT_DIR/../lib/version-gate.sh"
CORE_PATCH_GATE_RC=0
if [ -f "$VERSION_GATE_LIB" ]; then
    # shellcheck source=../lib/version-gate.sh
    source "$VERSION_GATE_LIB"
    if [ "${HESTIA_APT_HOOK:-0}" = "1" ]; then
        check_hestia_core_patch_compatibility "apt-hook" || CORE_PATCH_GATE_RC=$?
    else
        check_hestia_core_patch_compatibility "manual" || exit 1
    fi
fi

echo "--- Installing Mail Forward Policy (v-mail-forward-policy) ---"

install_root_file() {
    local mode="$1"
    local src="$2"
    local dst="$3"
    local parent
    parent="$(dirname "$dst")"
    [ -d "$parent" ] || install -d -m 0755 -o root -g root "$parent"
    rm -f "$dst"
    install -o root -g root -m "$mode" "$src" "$dst"
}

install_root_file 0755 "$SCRIPT_DIR/v-mail-forward-policy" "$HESTIA_BIN/v-mail-forward-policy"
echo "  -> [OK] Installed CLI script: $HESTIA_BIN/v-mail-forward-policy"

if [ ! -f "$CONF_FILE" ]; then
    install_root_file 0644 "$SCRIPT_DIR/mail-forward-policy.conf.sample" "$CONF_FILE"
    echo "  -> [OK] Created default configuration: $CONF_FILE (0644 root:root)"
else
    chown root:root "$CONF_FILE" 2>/dev/null || true
    chmod 0644 "$CONF_FILE" 2>/dev/null || true
    echo "  -> [INFO] Configuration already exists (preserved): $CONF_FILE"
fi

install_root_file 0644 "$SCRIPT_DIR/inc/mail_forward_policy.php" "$HESTIA/web/inc/mail_forward_policy.php"
echo "  -> [OK] Installed web policy helper: $HESTIA/web/inc/mail_forward_policy.php"

install_root_file 0644 "$SCRIPT_DIR/custom_scripts/mail-forward-policy-ui.php" "$HESTIA/web/js/custom_scripts/mail-forward-policy-ui.php"
echo "  -> [OK] Installed UI hint script: $HESTIA/web/js/custom_scripts/mail-forward-policy-ui.php"

if [ "$CORE_PATCH_GATE_RC" -eq 0 ]; then
    "$HESTIA_BIN/v-mail-forward-policy" --apply
    echo "  -> [OK] Applied web/API forward policy guards"
else
    echo "  -> [INFO] Skipped core PHP hook mutations (version gate held); standalone CLI/helper updated"
fi

APT_HOOK_LIB="$SCRIPT_DIR/../lib/apt-hook.sh"
REPO_ROOT="$(readlink -f "$SCRIPT_DIR/../.." 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"
if [ -f "$APT_HOOK_LIB" ] && [ -d "$APT_CONF_DIR" ]; then
    if [ -f "$APT_CONF_DIR/99hestia-custom-patches" ] && [ ! -L "$APT_CONF_DIR/99hestia-custom-patches" ]; then
        rm -f "$APT_CONF_DIR/99hestia-mail-forward-policy"
        echo "  -> [OK] APT post-invoke auto-heal covered by $APT_CONF_DIR/99hestia-custom-patches"
    else
        # shellcheck source=../lib/apt-hook.sh
        source "$APT_HOOK_LIB"
        install_hestia_apt_hook "$APT_CONF_DIR/99hestia-mail-forward-policy" "mail-forward-policy" "$REPO_ROOT" "--mail-forward-policy --apt-hook"
    fi
fi

echo "  -> [TIP] Check status anytime with 'v-mail-forward-policy --status' or scan redirects with 'v-mail-forward-policy --audit'"
