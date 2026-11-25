#!/bin/bash
# scripts/lib/apt-hook.sh
# Shared root-safety verification and APT DPkg::Post-Invoke auto-heal helpers.

repo_tree_is_root_safe() {
    local target="$1"
    [[ "$target" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    [[ "$target" != /tmp/* && "$target" != /var/tmp/* && "$target" != /dev/shm/* ]] || return 1
    [ -d "$target" ] && [ -f "$target/install.sh" ] && [ ! -L "$target/install.sh" ] || return 1

    # Verify every ancestor directory from / up to $target is root-owned and not group/world-writable
    local cur="$target"
    while true; do
        [ ! -L "$cur" ] && [ -O "$cur" ] || return 1
        local p
        p="$(stat -c '%a' "$cur" 2>/dev/null || echo '777')"
        [[ ! "$p" =~ [2367].$ && ! "$p" =~ [2367]$ ]] || return 1
        [ "$cur" = "/" ] && break
        cur="$(dirname "$cur")"
    done

    # Verify no file, subdirectory, or symlink inside $target is non-root-owned, a symlink, or group/world-writable
    local unsafe
    unsafe="$(find -P "$target" \( ! -user 0 -o -type l -o -perm /022 \) -print -quit 2>/dev/null || echo 'err')"
    [ -z "$unsafe" ]
}

install_hestia_apt_hook() {
    local hook_file="$1"
    local label="$2"
    local repo_root="$3"
    local install_args="${4:---apt-hook}"
    local hook_dir hook_base

    hook_dir="$(dirname "$hook_file")"
    hook_base="$(basename "$hook_file")"
    [ -d "$hook_dir" ] || return 0

    if [[ ! "$label" =~ ^[A-Za-z0-9_.-]+$ ]] || [[ ! "$install_args" =~ ^[-a-zA-Z0-9\ ]+$ ]]; then
        echo "  -> [WARN] Refused to install APT hook with unsafe metadata ($label)" >&2
        return 1
    fi

    if [ -f "$repo_root/install.sh" ] && [ ! -L "$repo_root/install.sh" ] && repo_tree_is_root_safe "$repo_root"; then
        local tmp_apt_hook hook_tpl
        tmp_apt_hook="$(umask 022 && mktemp "$hook_dir/.${hook_base}.XXXXXX")"
        IFS='' read -r -d '' hook_tpl << 'APT_EOF' || true
// Managed by hestiacp-useful-tools (__LABEL__)
// Automatically re-applies HestiaCP custom patches after apt/dpkg package updates
DPkg::Post-Invoke { "/bin/bash -c 'r=\"$1\"; [ -d \"$r\" ] && [ ! -L \"$r\" ] && [ -f \"$r/install.sh\" ] && [ ! -L \"$r/install.sh\" ] && [ -O \"$r\" ] && [ -O \"$r/install.sh\" ] || exit 0; cur=\"$r\"; while true; do [ ! -L \"$cur\" ] && [ -O \"$cur\" ] || exit 0; p=$(stat -c %a \"$cur\" 2>/dev/null || echo 777); [[ ! \"$p\" =~ [2367].$ && ! \"$p\" =~ [2367]$ ]] || exit 0; [ \"$cur\" = / ] && break; cur=$(dirname \"$cur\"); done; unsafe=$(find -P \"$r\" \( ! -user 0 -o -type l -o -perm /022 \) -print -quit 2>/dev/null || echo err); [ -z \"$unsafe\" ] && /bin/bash \"$r/install.sh\" __ARGS__ </dev/null >/dev/null 2>&1 || true' _ '__REPO__' || true"; };
APT_EOF
        hook_tpl="${hook_tpl//__LABEL__/$label}"
        hook_tpl="${hook_tpl//__ARGS__/$install_args}"
        hook_tpl="${hook_tpl//__REPO__/$repo_root}"
        printf '%s\n' "$hook_tpl" > "$tmp_apt_hook"
        chown root:root "$tmp_apt_hook"
        chmod 0644 "$tmp_apt_hook"
        if [ -f "$hook_file" ] && cmp -s "$tmp_apt_hook" "$hook_file"; then
            rm -f "$tmp_apt_hook"
            echo "  -> APT post-invoke hook already up to date: $hook_file"
        else
            mv -f "$tmp_apt_hook" "$hook_file"
            echo "  -> Installed APT post-invoke auto-heal hook: $hook_file"
        fi
    else
        if [ -f "$hook_file" ] || [ -L "$hook_file" ]; then
            rm -f "$hook_file"
            echo "  -> [WARN] Removed stale/unsafe APT hook: $hook_file"
        fi
        echo "  -> [WARN] Skipped APT hook ($hook_file): repo tree '$repo_root' and its ancestors must be root-owned, symlink-free, and non-world/group-writable"
    fi
}
