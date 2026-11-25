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
        local tmp_apt_hook
        tmp_apt_hook="$(umask 022 && mktemp "$hook_dir/.${hook_base}.XXXXXX")"
        cat > "$tmp_apt_hook" << APT_EOF
// Managed by hestiacp-useful-tools ($label)
// Automatically re-applies HestiaCP custom patches after apt/dpkg package updates
DPkg::Post-Invoke { "if [ -d '$repo_root' ] && [ ! -L '$repo_root' ] && [ -f '$repo_root/install.sh' ] && [ ! -L '$repo_root/install.sh' ] && [ -O '$repo_root' ] && [ -O '$repo_root/install.sh' ] && /bin/bash -c 'cur=$repo_root; while true; do [ ! -L \$cur ] && [ -O \$cur ] || exit 1; p=\$(stat -c %a \$cur 2>/dev/null || echo 777); [[ ! \$p =~ [2367].\$ && ! \$p =~ [2367]\$ ]] || exit 1; [ \$cur = / ] && break; cur=\$(dirname \$cur); done' && ! find -P '$repo_root' \( ! -user 0 -o -type l -o -perm /022 \) -print -quit 2>/dev/null | grep -q .; then /bin/bash '$repo_root/install.sh' $install_args </dev/null >/dev/null 2>&1 || true; fi"; };
APT_EOF
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
