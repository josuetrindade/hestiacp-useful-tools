#!/bin/bash
# scripts/backup-core-patches/install.sh
# Installation module for the Backup Native Patches

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
HESTIA_BIN="$HESTIA/bin"
HESTIA_CONF="$HESTIA/conf/hestia.conf"
RETENTION_CONF="/etc/hestiacp-backup-retention.conf"

for arg in "$@"; do
    case "$arg" in
        --allow-untested-hestia) export ALLOW_UNTESTED_HESTIA=1 ;;
        --apt-hook)              export HESTIA_APT_HOOK=1 ;;
    esac
done

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

echo "--- Installing Backup Core Patches ---"

# 1. Cleanup old wrapper system (Migration from v1 architecture)
if [ -L "$HESTIA_BIN/v-backup-users-custom" ] || [ -f "$HESTIA_BIN/v-backup-users-custom" ]; then
    rm -f "$HESTIA_BIN/v-backup-users-custom"
    rm -f "/etc/hestiacp-backup-custom.conf"
    echo "  -> Cleaned up old v-backup-users-custom wrapper (Arch v1)."
fi
if [ -d "$HESTIA_BIN/lib" ] && [ -f "$HESTIA_BIN/lib/core.sh" ] && [ -f "$HESTIA_BIN/lib/retention.sh" ] && [ -f "$HESTIA_BIN/lib/remote.sh" ]; then
    rm -rf "$HESTIA_BIN/lib"
    echo "  -> Cleaned up orphaned Arch v1 backup library ($HESTIA_BIN/lib)."
fi

install_root_bin() {
    local src="$1"
    local dst="$2"
    rm -f "$dst"
    install -o root -g root -m 0755 "$src" "$dst"
}

# 2. Install the local organization hook (root-owned copy, never a symlink into non-root checkout)
install_root_bin "$SCRIPT_DIR/hooks/v-backup-user-hook" "$HESTIA_BIN/v-backup-user-hook"
echo "  -> Installed backup organization hook: v-backup-user-hook"

# 2.1 Install the HTML notification hooks
install_root_bin "$SCRIPT_DIR/hooks/v-backup-user-notify-hook" "$HESTIA_BIN/v-backup-user-notify-hook"
install_root_bin "$SCRIPT_DIR/hooks/v-backup-users-notify-hook" "$HESTIA_BIN/v-backup-users-notify-hook"
echo "  -> Installed HTML notification hooks"

# 2.2 Install optional retention command, Restic manager, archive verifier, and native v-backup-users hook
install_root_bin "$SCRIPT_DIR/bin/v-prune-backups" "$HESTIA_BIN/v-prune-backups"
install_root_bin "$SCRIPT_DIR/bin/v-verify-backups" "$HESTIA_BIN/v-verify-backups"
install_root_bin "$SCRIPT_DIR/bin/v-restic-manager" "$HESTIA_BIN/v-restic-manager"
install_root_bin "$SCRIPT_DIR/hooks/v-backup-users-retention-hook" "$HESTIA_BIN/v-backup-users-retention-hook"
if [ ! -f "$RETENTION_CONF" ]; then
    install -o root -g root -m 0600 "$SCRIPT_DIR/config/backup-retention.conf.sample" "$RETENTION_CONF"
    echo "  -> Installed optional retention config: $RETENTION_CONF"
else
    chown root:root "$RETENTION_CONF" 2>/dev/null || true
    chmod 600 "$RETENTION_CONF" 2>/dev/null || true
    echo "  -> Retention config already exists (skipped): $RETENTION_CONF"
fi
echo "  -> Installed optional native retention hook: v-prune-backups"
echo "  -> Installed backup integrity verifier: v-verify-backups"
echo "  -> Installed Restic incremental & Master Key manager: v-restic-manager"

# 2.3 Isolate Backblaze B2 StaticX runtime extraction outside world-writable /tmp
install -d -m 0700 -o root -g root /var/cache/b2-staticx 2>/dev/null || true
if [ -x /usr/local/bin/b2 ] && [ -d /usr/local/sbin ]; then
    cat > /usr/local/sbin/b2 << 'B2_SHIM_EOF'
#!/usr/bin/env bash
# Managed by hestiacp-useful-tools: isolate Backblaze B2 StaticX extraction from /tmp
_b2_tmp="${TMPDIR:-/tmp}"
if [ "$(id -u)" -eq 0 ] && install -d -m 0700 -o root -g root /var/cache/b2-staticx 2>/dev/null; then
    _b2_tmp="/var/cache/b2-staticx"
fi
TMPDIR="$_b2_tmp" exec /usr/local/bin/b2 "$@"
B2_SHIM_EOF
    chown root:root /usr/local/sbin/b2
    chmod 0755 /usr/local/sbin/b2
    echo "  -> Installed B2 StaticX TMPDIR isolation shim: /usr/local/sbin/b2 -> /var/cache/b2-staticx"
fi

"$HESTIA_BIN/v-verify-backups" --quiet >/dev/null 2>&1 || true

# 3. Apply core Hestia patches (B2 paths, symlink delete, v-backup-user post-hook)
if [ "$CORE_PATCH_GATE_RC" -eq 0 ] && [ -f "$LIB_DIR/hestia.sh" ]; then
    _log() { echo "  -> $1"; }
    source "$LIB_DIR/hestia.sh"
    apply_hestia_patches
elif [ "$CORE_PATCH_GATE_RC" -ne 0 ]; then
    echo "  -> [INFO] Skipped core Hestia file mutations (version gate held); standalone Restic/backup helpers updated."
fi

# 3.1 Ensure APT DPkg::Post-Invoke hook re-applies patches automatically after HestiaCP updates
APT_CONF_DIR="${APT_CONF_DIR:-/etc/apt/apt.conf.d}"
APT_HOOK_FILE="$APT_CONF_DIR/99hestia-custom-patches"
REPO_ROOT="$(readlink -f "$SCRIPT_DIR/../.." 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"
APT_HOOK_LIB="$SCRIPT_DIR/../lib/apt-hook.sh"

if [ -f "$APT_HOOK_LIB" ] && [ -d "$APT_CONF_DIR" ]; then
    # shellcheck source=../lib/apt-hook.sh
    source "$APT_HOOK_LIB"
    install_hestia_apt_hook "$APT_HOOK_FILE" "backup-core-patches" "$REPO_ROOT" "--apt-hook"
    if [ -f "$APT_HOOK_FILE" ] && { [ -f "$APT_CONF_DIR/99hestia-mail-forward-policy" ] || [ -L "$APT_CONF_DIR/99hestia-mail-forward-policy" ]; }; then
        rm -f "$APT_CONF_DIR/99hestia-mail-forward-policy"
    fi
fi

# 4. Check remote backup status and guide user
echo ""
b2_conf="$HESTIA/conf/b2.backup.conf"
if [ -f "$b2_conf" ] && grep -q "BUCKET=" "$b2_conf" 2>/dev/null; then
    b2_bucket=$(grep "^BUCKET=" "$b2_conf" | cut -d"'" -f2 || true)
    echo "  ✅ B2 cloud backup configured (bucket: $b2_bucket)"
    echo "  Backups will be uploaded to organized paths: YYYY/MM_MONTH/user/"
else
    echo "  ℹ️  Cloud backup is not configured (local-only mode)"
    echo ""
    echo "  To enable cloud backups natively, run ONE of these:"
    echo ""
    echo "    Backblaze B2:"
    echo "      v-add-backup-host b2 BUCKET_NAME KEY_ID APP_KEY"
    echo ""
    echo "  See README.md for detailed setup instructions."
fi
if [ -f "$HESTIA/conf/restic.conf" ] && grep -q "^BACKUP_INCREMENTAL='yes'" "$HESTIA_CONF" 2>/dev/null; then
    echo "  ✅ Restic incremental backups enabled (manage Master Key & daily runs via: v-restic-manager --status)"
fi

echo ""
echo "[OK] Backup Native Patches installed successfully."
