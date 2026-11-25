# Mail Forward Policy (`v-mail-forward-policy`)

*Prevents non-admin HestiaCP users from adding external email forwards or external Catch-All redirects that hurt your server's IP reputation, while still allowing administrators (including when impersonating a client) to configure exceptions.*

---

## Why This Exists

When a client adds an automatic forward from `user@clientdomain.tld` to `@gmail.com` or `@outlook.com`:

- Even with SRS enabled to fix SPF alignment, **every incoming spam message forwarded by your server leaves from your server's IP**.
- Large providers (Google, Microsoft) track forwarder reputation and frequently rate-limit or blacklist shared hosting IPs when forwarded spam hits recipient mailboxes.
- Clients should connect Gmail, Outlook, or mobile mail apps over **IMAP/SMTP** instead of forwarding all mail out.

---

## 1. Installation

### Full toolkit install
When you run `bash install.sh` or `bash install.sh --all`, the `mail-forward-policy` module is installed and applied automatically alongside the shared APT auto-heal hook (`/etc/apt/apt.conf.d/99hestia-custom-patches`).

### Standalone install
To install or update only `mail-forward-policy`, run from the repository root:

```bash
cd /root/hestiacp-useful-tools
bash install.sh --mail-forward-policy
```

Or run the module installer directly:

```bash
cd /root/hestiacp-useful-tools/scripts/mail-forward-policy
bash install.sh
```

Core PHP hooks are gated by `scripts/lib/version-gate.sh` (currently pinned to HestiaCP `1.10.10`). If you intentionally run on a different verified HestiaCP release during a manual run, pass `--allow-untested-hestia`:

```bash
bash install.sh --mail-forward-policy --allow-untested-hestia
```

Re-running any installer is idempotent and preserves your existing `/etc/hestiacp-mail-forward-policy.conf` settings while keeping file permissions at `0644 root:root`.

---

## 2. File Layout

- **CLI Manager & Auditor:** `/usr/local/hestia/bin/v-mail-forward-policy` (`0755 root:root`)
- **Configuration:** `/etc/hestiacp-mail-forward-policy.conf` (`0644 root:root`)
- **Policy Helper:** `/usr/local/hestia/web/inc/mail_forward_policy.php` (`0644 root:root`)
- **Panel UI Hint:** `/usr/local/hestia/web/js/custom_scripts/mail-forward-policy-ui.php` (`0644 root:root`)
- **APT Auto-Heal Hook:** `/etc/apt/apt.conf.d/99hestia-mail-forward-policy` (standalone installs) or `/etc/apt/apt.conf.d/99hestia-custom-patches` (full toolkit installs)
- **Core Hook Anchors:** Minimal marker blocks in:
  - `/usr/local/hestia/web/add/mail/index.php`
  - `/usr/local/hestia/web/edit/mail/index.php`
  - `/usr/local/hestia/web/api/index.php`

---

## 3. Configuration (`/etc/hestiacp-mail-forward-policy.conf`)

> Permissions must stay `0644 root:root` so `hestiaweb` (PHP-FPM) can read policy settings. Never place secrets in this file.

| Option | Default | Description |
|---|---|---|
| `ENABLED` | `"yes"` | Master toggle (`"yes"` or `"no"`). |
| `SCOPE` | `"user"` | `"user"` allows forwarding only to mail domains owned by the same HestiaCP user (prevents cross-tenant domain discovery). `"server"` allows any mail domain hosted on the server (`/etc/exim4/domains/`). |
| `BLOCK_CATCHALL` | `"yes"` | Also blocks external addresses in domain Catch-All settings. |
| `ENFORCE_API` | `"yes"` | Enforces the same rule for non-admin REST API keys when `API_SYSTEM=2`. |
| `ENABLE_UI_HINT` | `"yes"` | Displays an informational hint under `Forward to` and `Catch-All Email` for non-admin users. |
| `ALLOWLIST_DOMAINS` | `""` | Optional comma-separated list of permitted external destination domains (e.g. `"corp.example.com,partner.example.org"`). |

---

## 4. How Admin Exceptions & Editing Work

- **Administrators & Impersonation:** HestiaCP preserves `$_SESSION["userContext"] === "admin"` when an admin impersonates a client via "Log in as ...". An admin can add an external forward or Catch-All for any client at any time.
- **Preserving Existing Exceptions:** When a non-admin user edits a mailbox that already has an admin-approved external forward, only **newly added** forward addresses are checked. The user can update their password, quota, aliases, auto-reply, or remove the external forward without errors.
- **Blackhole Allowed:** `:blackhole:` ("Discard all mail") is always allowed.
- **No Orphaned Mailboxes:** When creating a new mail account, forwarding targets are validated before `v-add-mail-account` executes.

---

## 5. CLI Usage & Verification

```bash
# Check installation, config readability, and core hook status (exit 0 when healthy)
v-mail-forward-policy --status

# Audit all accounts, Catch-Alls, ~/.forward files, and Dovecot Sieve redirects
v-mail-forward-policy --audit
v-mail-forward-policy --audit --json

# Test whether a destination address is allowed for a non-admin user (exit 0 allowed, 1 blocked)
v-mail-forward-policy --check user1 recipient@gmail.com

# Verify HestiaCP mail domain quotas (non-admins should match active domain count, not unlimited)
v-list-user user1 json | grep MAIL_DOMAINS

# Re-apply core hooks after manual changes
v-mail-forward-policy --apply

# Remove core hooks, helper/UI files, and standalone APT hook (preserves config)
v-mail-forward-policy --disable
```

`v-security-audit --system` also checks for active external account forwards and Catch-All redirects (`S67`), and `v-harden-server --cron-heal` checks `v-mail-forward-policy --status` daily at `04:50` (logging a warning if hooks are missing when no version hold is active).

---

## 6. Upgrade Safety, Disabling & Scope Boundaries

- **HestiaCP Package Upgrades & APT Auto-Heal:** `/usr/local/hestia/web/inc/mail_forward_policy.php` and `/usr/local/hestia/web/js/custom_scripts/mail-forward-policy-ui.php` survive panel upgrades automatically. When APT upgrades HestiaCP packages and overwrites `web/{add/mail,edit/mail,api}/index.php`:
  - Standalone installations install `/etc/apt/apt.conf.d/99hestia-mail-forward-policy` (only when the repository tree and all ancestor directories up to `/` are root-owned, symlink-free, and non-group/world-writable), which runs `install.sh --mail-forward-policy --apt-hook` automatically.
  - Full-toolkit installations use `/etc/apt/apt.conf.d/99hestia-custom-patches`, which covers `mail-forward-policy` alongside `backup-core-patches` and `nginx-txt-nocache` (the redundant standalone hook file is automatically removed).
  - Both hooks enforce `scripts/lib/version-gate.sh`: on matching HestiaCP `1.10.10`, hooks are refreshed automatically; on an untested HestiaCP version, core PHP mutations are safely placed on hold and an admin notification/email is sent once.
- **Disabling Permanently:** On full-toolkit installations where `99hestia-custom-patches` re-applies core modules after APT upgrades, set `ENABLED="no"` in `/etc/hestiacp-mail-forward-policy.conf` if you want the policy to remain inactive across future updates. Running `v-mail-forward-policy --disable` restores all core PHP files cleanly and removes the standalone APT hook (`99hestia-mail-forward-policy`).
- **Recommended Quota Hardening (`MAIL_DOMAINS`):** HestiaCP's `v-add-mail-domain` only checks whether another local user owns a domain, without DNS/MX verification. Do not leave non-admin users with `MAIL_DOMAINS='unlimited'`; set per-user `MAIL_DOMAINS` limits matching their actual domain count (`v-change-user-config-value <user> MAIL_DOMAINS <count>`) so a client cannot temporarily add an external domain (such as `gmail.com`), create a forward to it, and delete it afterwards.
- **Direct CLI & Backup Restore:** `v-add-mail-account-forward` and `v-restore-user` run as `root` and are not blocked at write time; monitor restored or legacy redirects with `v-mail-forward-policy --audit` and `v-security-audit --system` (`S67`).
- **Dovecot Sieve / Roundcube:** Default HestiaCP installs do not enable `managesieve`. If you enable Sieve filters on your server, configure Sieve capabilities separately and monitor with `v-mail-forward-policy --audit`.
