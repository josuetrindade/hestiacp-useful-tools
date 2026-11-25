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

Install via the standalone shortcut or the full toolkit installer:

```bash
cd /root/hestiacp-useful-tools
bash install.sh --mail-forward-policy
```

Or run the module installer directly:

```bash
cd /root/hestiacp-useful-tools/scripts/mail-forward-policy
bash install.sh
```

---

## 2. File Layout

- **CLI Manager & Auditor:** `/usr/local/hestia/bin/v-mail-forward-policy` (`0755 root:root`)
- **Configuration:** `/etc/hestiacp-mail-forward-policy.conf` (`0644 root:root`)
- **Policy Helper:** `/usr/local/hestia/web/inc/mail_forward_policy.php` (`0644 root:root`)
- **Panel UI Hint:** `/usr/local/hestia/web/js/custom_scripts/mail-forward-policy-ui.php` (`0644 root:root`)
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

## 5. CLI Usage

```bash
# Check installation and hook status
v-mail-forward-policy --status

# Audit all accounts, Catch-Alls, ~/.forward files, and Dovecot Sieve redirects
v-mail-forward-policy --audit
v-mail-forward-policy --audit --json

# Test whether a destination address is allowed for a non-admin user
v-mail-forward-policy --check user1 recipient@gmail.com

# Re-apply core hooks after manual changes
v-mail-forward-policy --apply

# Remove core hooks and UI/helper files cleanly (preserves /etc/hestiacp-mail-forward-policy.conf)
v-mail-forward-policy --disable
```

`v-security-audit --system` also checks for active external account forwards and Catch-All redirects (`S67`).

---

## 6. Upgrade Safety & Scope Boundaries

- **HestiaCP Package Upgrades:** `/usr/local/hestia/web/inc/mail_forward_policy.php` and `/usr/local/hestia/web/js/custom_scripts/mail-forward-policy-ui.php` survive panel upgrades automatically. When APT upgrades HestiaCP and overwrites `web/{add/mail,edit/mail,api}/index.php`, `/etc/apt/apt.conf.d/99hestia-custom-patches` re-applies hooks if the running HestiaCP version matches the verified version pin in `scripts/lib/version-gate.sh`.
- **Direct CLI Access:** `v-add-mail-account-forward` itself is not restricted, so root automation and admin workflows keep working unchanged.
- **Dovecot Sieve / Roundcube:** Default HestiaCP installs do not enable `managesieve`. If you enable Sieve filters on your server, configure Sieve capabilities separately and monitor with `v-mail-forward-policy --audit`.
