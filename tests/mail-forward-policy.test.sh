#!/bin/bash
# =============================================================================
# Mail Forward Policy Regression & Behavior Test Suite
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "  [PASS] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  [FAIL] $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "================================================================="
echo " Running Mail Forward Policy Tests"
echo "================================================================="

if ! command -v php >/dev/null 2>&1; then
    fail "PHP CLI binary is required to run mail-forward-policy tests"
    exit 1
fi

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mfp-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

HELPER_SRC="$REPO_ROOT/scripts/mail-forward-policy/inc/mail_forward_policy.php"
UI_SRC="$REPO_ROOT/scripts/mail-forward-policy/custom_scripts/mail-forward-policy-ui.php"
CLI_SRC="$REPO_ROOT/scripts/mail-forward-policy/v-mail-forward-policy"

# 1. PHP & Bash syntax checks
if php -l "$HELPER_SRC" >/dev/null 2>&1 && php -l "$UI_SRC" >/dev/null 2>&1; then
    pass "mail_forward_policy.php and mail-forward-policy-ui.php pass php -l"
else
    fail "PHP syntax error in mail-forward-policy PHP files"
fi

if bash -n "$CLI_SRC" && bash -n "$REPO_ROOT/scripts/mail-forward-policy/install.sh"; then
    pass "v-mail-forward-policy and install.sh pass bash -n"
else
    fail "Bash syntax error in mail-forward-policy scripts"
fi

# 2. Direct HTTP guard test on custom_scripts/mail-forward-policy-ui.php
ui_direct_out=$(php -r 'include $argv[1];' "$UI_SRC" 2>/dev/null)
if [ -z "$ui_direct_out" ]; then
    pass "Direct execution of mail-forward-policy-ui.php without HESTIA_DIR_BIN returns empty/404 guard"
else
    fail "mail-forward-policy-ui.php emitted output without HESTIA_DIR_BIN: $ui_direct_out"
fi

# 3. Fixture HestiaCP tree for patch lifecycle, --audit, --check, and PHP runtime behavior tests
HESTIA_FIX="$TEST_ROOT/hestia"
HOME_FIX="$TEST_ROOT/home"
EXIM_FIX="$TEST_ROOT/exim_domains"
BAK_FIX="$TEST_ROOT/bak"
MOCK_BIN="$TEST_ROOT/mockbin"
CONF_FIX="$TEST_ROOT/mail-forward-policy.conf"

mkdir -p "$HESTIA_FIX/web/add/mail" "$HESTIA_FIX/web/edit/mail" "$HESTIA_FIX/web/api" \
         "$HESTIA_FIX/web/inc" "$HESTIA_FIX/web/js/custom_scripts" "$HESTIA_FIX/bin" \
         "$HESTIA_FIX/data/users/admin" "$HESTIA_FIX/data/users/user1/mail" "$HESTIA_FIX/data/users/user2/mail" \
         "$HOME_FIX/user1/mail/user1.example/sales/sieve" "$HOME_FIX/user2" \
         "$EXIM_FIX/user1.example" "$EXIM_FIX/user2.example" "$MOCK_BIN"

cp "$HELPER_SRC" "$HESTIA_FIX/web/inc/mail_forward_policy.php"
cp "$UI_SRC" "$HESTIA_FIX/web/js/custom_scripts/mail-forward-policy-ui.php"

cat > "$HESTIA_FIX/web/add/mail/index.php" << 'EOF'
<?php
$user = "'user1'";
if (!empty($_POST["ok_acc"])) {
	// Add Mail Account
	if (empty($_SESSION["error_msg"])) {
		echo "CREATED\n";
	}
}
EOF

cat > "$HESTIA_FIX/web/edit/mail/index.php" << 'EOF'
<?php
$user = "'user1'";
if (!empty($_POST["save"]) && empty($_GET["account"])) {
	// Change catchall address
	if (!empty($v_catchall) && !empty($_POST["v_catchall"]) && empty($_SESSION["error_msg"])) {
		echo "CA_CHANGED\n";
	}
}
if (!empty($_POST["save"]) && !empty($_GET["account"])) {
	// Change forwarders to :blackhole:
	if (empty($_SESSION["error_msg"]) && !empty($_POST["v_blackhole"])) {
		echo "BH\n";
	}
	// Change forwarders
	if (empty($_SESSION["error_msg"]) && empty($_POST["v_blackhole"])) {
		echo "FWD_CHANGED\n";
	}
}
EOF

cat > "$HESTIA_FIX/web/api/index.php" << 'EOF'
<?php
function api_legacy(array $request_data) {
	if (false) {
		$return_var = 0;
	} else {
		// Prepare command
		$cmdquery = "legacy";
	}
}
function api_connection(array $request_data) {
	$key_user = "user1";
	$root_user = "admin";
	$hst_cmd = $request_data["cmd"] ?? "";
	$hst_cmd_args = $request_data["args"] ?? [];
	$hst_return = "data";
	// Prepare command
	$cmdquery = HESTIA_CMD . escapeshellcmd($hst_cmd);

	// Prepare arguments
	return $cmdquery;
}
EOF

cp -a "$HESTIA_FIX/web/add/mail/index.php" "$TEST_ROOT/orig_add.php"
cp -a "$HESTIA_FIX/web/edit/mail/index.php" "$TEST_ROOT/orig_edit.php"
cp -a "$HESTIA_FIX/web/api/index.php" "$TEST_ROOT/orig_api.php"

cp "$REPO_ROOT/scripts/mail-forward-policy/mail-forward-policy.conf.sample" "$CONF_FIX"

# 3a. Patch --apply, idempotency, --status, and --disable rollback byte-for-byte
if HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" MFP_BAK_DIR="$BAK_FIX" bash "$CLI_SRC" --apply >/dev/null 2>&1 && \
   php -l "$HESTIA_FIX/web/add/mail/index.php" >/dev/null 2>&1 && \
   php -l "$HESTIA_FIX/web/edit/mail/index.php" >/dev/null 2>&1 && \
   php -l "$HESTIA_FIX/web/api/index.php" >/dev/null 2>&1; then
    pass "--apply patches add/edit/api PHP files and all pass php -l"
else
    fail "--apply failed or produced invalid PHP syntax"
fi

if HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" MFP_BAK_DIR="$BAK_FIX" bash "$CLI_SRC" --status >/dev/null 2>&1; then
    pass "--status reports exit 0 after --apply"
else
    fail "--status returned non-zero after --apply"
fi

# Apply a second time to verify idempotency (no duplicate marker blocks)
HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" MFP_BAK_DIR="$BAK_FIX" bash "$CLI_SRC" --apply >/dev/null 2>&1
add_count=$(grep -c "hestia-mail-forward-policy-v1-add-start" "$HESTIA_FIX/web/add/mail/index.php")
api_count=$(grep -c "hestia-mail-forward-policy-v1-api-start" "$HESTIA_FIX/web/api/index.php")
legacy_hit=$(sed -n '/function api_legacy/,/^}/p' "$HESTIA_FIX/web/api/index.php" | grep -c "hestia-mail-forward-policy" || true)
if [ "$add_count" -eq 1 ] && [ "$api_count" -eq 1 ] && [ "$legacy_hit" -eq 0 ]; then
    pass "--apply is idempotent and injects API hook inside api_connection() only (not api_legacy)"
else
    fail "--apply duplication or wrong api_legacy placement (add=$add_count api=$api_count legacy=$legacy_hit)"
fi

if HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" MFP_BAK_DIR="$BAK_FIX" bash "$CLI_SRC" --disable >/dev/null 2>&1 && \
   cmp -s "$TEST_ROOT/orig_add.php" "$HESTIA_FIX/web/add/mail/index.php" && \
   cmp -s "$TEST_ROOT/orig_edit.php" "$HESTIA_FIX/web/edit/mail/index.php" && \
   cmp -s "$TEST_ROOT/orig_api.php" "$HESTIA_FIX/web/api/index.php" && \
   [ ! -f "$HESTIA_FIX/web/inc/mail_forward_policy.php" ] && \
   [ ! -f "$HESTIA_FIX/web/js/custom_scripts/mail-forward-policy-ui.php" ]; then
    pass "--disable removes markers byte-for-byte and removes helper/UI files"
else
    fail "--disable did not cleanly restore original core files or remove helpers"
fi

# Re-install helpers + patches for remaining tests
cp "$HELPER_SRC" "$HESTIA_FIX/web/inc/mail_forward_policy.php"
cp "$UI_SRC" "$HESTIA_FIX/web/js/custom_scripts/mail-forward-policy-ui.php"
HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" MFP_BAK_DIR="$BAK_FIX" bash "$CLI_SRC" --apply >/dev/null 2>&1

# 4. Functional PHP policy tests (admin, impersonation, non-admin, scope=user vs server, allowlist, catchall, API)
cat > "$MOCK_BIN/v-list-mail-domains" << 'EOF'
#!/bin/bash
u="$1"
case "$u" in
    user1) echo '{"user1.example": {}}' ;;
    user2) echo '{"user2.example": {}}' ;;
    *)     echo '{}' ;;
esac
EOF
cat > "$MOCK_BIN/v-list-user" << 'EOF'
#!/bin/bash
u="$1"
case "$u" in
    admin|secadmin) echo "{\"$u\": {\"ROLE\": \"admin\"}}" ;;
    *)              echo "{\"$u\": {\"ROLE\": \"user\"}}" ;;
esac
EOF
chmod +x "$MOCK_BIN/v-list-mail-domains" "$MOCK_BIN/v-list-user"

php_test_out=$(php -r '
define("HESTIA_DIR_BIN", $argv[1] . "/");
define("HESTIA_MFP_TEST_MODE", true);
define("HESTIA_MFP_SKIP_LOG", true);
define("HESTIA_MFP_CMD_PREFIX", $argv[1] . "/");
define("HESTIA_MFP_EXIM_DOMAINS_DIR", $argv[2]);
require_once $argv[3];

$conf_user = $argv[4] . "/conf_user.conf";
$conf_server = $argv[4] . "/conf_server.conf";
$conf_allow = $argv[4] . "/conf_allow.conf";
$conf_nobh = $argv[4] . "/conf_nobh.conf";

file_put_contents($conf_user, "ENABLED=\"yes\"\nSCOPE=\"user\"\nBLOCK_CATCHALL=\"yes\"\nENFORCE_API=\"yes\"\n");
file_put_contents($conf_server, "ENABLED=\"yes\"\nSCOPE=\"server\"\nBLOCK_CATCHALL=\"yes\"\nENFORCE_API=\"yes\"\n");
file_put_contents($conf_allow, "ENABLED=\"yes\"\nSCOPE=\"user\"\nBLOCK_CATCHALL=\"yes\"\nENFORCE_API=\"yes\"\nALLOWLIST_DOMAINS=\"corp.example.org\"\n");
file_put_contents($conf_nobh, "ENABLED=\"yes\"\nSCOPE=\"user\"\nBLOCK_CATCHALL=\"no\"\nENFORCE_API=\"yes\"\n");

function assert_case(string $name, ?string $actual, bool $expect_null): void {
    $is_null = ($actual === null);
    if ($is_null !== $expect_null) {
        fwrite(STDERR, "FAIL [$name]: expected " . ($expect_null ? "NULL" : "ERROR") . ", got " . var_export($actual, true) . "\n");
        exit(1);
    }
}

// A) Non-admin user with SCOPE=user
putenv("HESTIA_MFP_CONF=$conf_user");
$_SESSION = ["userContext" => "user", "look" => ""];
assert_case("user own domain allowed", hst_mfp_validate_web_forwards(["sales@user1.example"], "user1", "forward"), true);
assert_case("user blackhole allowed", hst_mfp_validate_web_forwards([":blackhole:"], "user1", "forward"), true);
assert_case("user other tenant blocked (anti-enum)", hst_mfp_validate_web_forwards(["ceo@user2.example"], "user1", "forward"), false);
assert_case("user external gmail blocked", hst_mfp_validate_web_forwards(["lazy@gmail.com"], "user1", "forward"), false);
assert_case("user uppercase trailing dot blocked", hst_mfp_validate_web_forwards(["LAZY@GMAIL.COM."], "user1", "forward"), false);
assert_case("user external catchall blocked", hst_mfp_validate_web_forwards(["inbox@outlook.com"], "user1", "catchall"), false);

// B) Admin direct + Admin impersonating user1 -> both bypass
$_SESSION = ["userContext" => "admin", "look" => ""];
assert_case("admin direct bypasses", hst_mfp_validate_web_forwards(["lazy@gmail.com"], "user1", "forward"), true);
$_SESSION = ["userContext" => "admin", "look" => "user1"];
assert_case("admin impersonation bypasses forward", hst_mfp_validate_web_forwards(["lazy@gmail.com"], "user1", "forward"), true);
assert_case("admin impersonation bypasses catchall", hst_mfp_validate_web_forwards(["lazy@gmail.com"], "user1", "catchall"), true);

// C) SCOPE=server allows other tenant hosted domain, still blocks external
putenv("HESTIA_MFP_CONF=$conf_server");
$_SESSION = ["userContext" => "user", "look" => ""];
assert_case("scope=server allows user2.example", hst_mfp_validate_web_forwards(["ceo@user2.example"], "user1", "forward"), true);
assert_case("scope=server blocks outlook.com", hst_mfp_validate_web_forwards(["lazy@outlook.com"], "user1", "forward"), false);

// D) ALLOWLIST_DOMAINS
putenv("HESTIA_MFP_CONF=$conf_allow");
assert_case("allowlist domain allowed", hst_mfp_validate_web_forwards(["boss@CORP.EXAMPLE.ORG"], "user1", "forward"), true);
assert_case("non-allowlisted external blocked", hst_mfp_validate_web_forwards(["boss@gmail.com"], "user1", "forward"), false);

// E) BLOCK_CATCHALL=no allows external catchall
putenv("HESTIA_MFP_CONF=$conf_nobh");
assert_case("block_catchall=no allows catchall", hst_mfp_validate_web_forwards(["boss@gmail.com"], "user1", "catchall"), true);

// F) Existing admin-set external forward preserved when unchanged/removed, blocked only on new external
putenv("HESTIA_MFP_CONF=$conf_user");
$existing = ["vip@gmail.com", "local@user1.example"];
$posted_keep = hst_mfp_parse_targets("VIP@GMAIL.COM\nlocal@user1.example");
$added_keep = array_values(array_udiff($posted_keep, $existing, "strcasecmp"));
assert_case("keeping existing external fwd allowed", hst_mfp_validate_web_forwards($added_keep, "user1", "forward"), true);
$posted_add = hst_mfp_parse_targets("vip@gmail.com, another@gmail.com");
$added_new = array_values(array_udiff($posted_add, $existing, "strcasecmp"));
assert_case("adding extra external fwd blocked", hst_mfp_validate_web_forwards($added_new, "user1", "forward"), false);

// G) API command checks
assert_case("API external fwd blocked for user1", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg4" => "lazy@gmail.com"], "user1", "admin"), false);
assert_case("API external catchall blocked for user1", hst_mfp_validate_api_command("v-add-mail-domain-catchall", ["arg1" => "user1", "arg3" => "lazy@gmail.com"], "user1", "admin"), false);
assert_case("API own fwd allowed for user1", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg4" => "info@user1.example"], "user1", "admin"), true);
assert_case("API blackhole allowed for user1", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg4" => ":blackhole:"], "user1", "admin"), true);
assert_case("API external allowed for secadmin", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg4" => "lazy@gmail.com"], "secadmin", "admin"), true);
assert_case("API external allowed for root_user", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg4" => "lazy@gmail.com"], "admin", "admin"), true);

echo "ALL_PHP_CASES_OK\n";
' "$MOCK_BIN" "$EXIM_FIX" "$HELPER_SRC" "$TEST_ROOT" 2>&1)
if printf '%s\n' "$php_test_out" | grep -q 'ALL_PHP_CASES_OK'; then
    pass "All PHP web/API policy cases passed (impersonation, SCOPE=user vs server, allowlist, catchall, existing exception, API)"
else
    fail "PHP functional policy test failed: $php_test_out"
fi

# 5. CLI --check and --audit + Security Audit S67
cat > "$HESTIA_FIX/data/users/admin/user.conf" << 'EOF'
ROLE='admin'
SUSPENDED='no'
EOF
cat > "$HESTIA_FIX/data/users/user1/user.conf" << 'EOF'
ROLE='user'
SUSPENDED='no'
EOF
cat > "$HESTIA_FIX/data/users/user2/user.conf" << 'EOF'
ROLE='user'
SUSPENDED='no'
EOF
cat > "$HESTIA_FIX/data/users/user1/mail.conf" << 'EOF'
DOMAIN='user1.example' CATCHALL='ext-ca@outlook.com' SUSPENDED='no'
EOF
cat > "$HESTIA_FIX/data/users/user1/mail/user1.example.conf" << 'EOF'
ACCOUNT='sales' FWD='ext-fwd@gmail.com,info@user1.example' FWD_ONLY='yes' SUSPENDED='no'
ACCOUNT='bh' FWD=':blackhole:' FWD_ONLY='' SUSPENDED='no'
EOF
cat > "$HESTIA_FIX/data/users/user2/mail.conf" << 'EOF'
DOMAIN='user2.example' CATCHALL='' SUSPENDED='no'
EOF
echo "dotfwd@gmail.com" > "$HOME_FIX/user2/.forward"
cat > "$HOME_FIX/user1/mail/user1.example/sales/sieve/custom.sieve" << 'EOF'
redirect :copy "sieve-ext@yahoo.com";
EOF

check_block_rc=0
HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash "$CLI_SRC" --check user1 lazy@gmail.com >/dev/null 2>&1 || check_block_rc=$?
check_allow_rc=0
HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash "$CLI_SRC" --check user1 info@user1.example >/dev/null 2>&1 || check_allow_rc=$?
check_admin_rc=0
HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash "$CLI_SRC" --check admin lazy@gmail.com >/dev/null 2>&1 || check_admin_rc=$?
if [ "$check_block_rc" -eq 1 ] && [ "$check_allow_rc" -eq 0 ] && [ "$check_admin_rc" -eq 0 ]; then
    pass "CLI --check returns blocked=1 for external user forward, 0 for own domain and admin"
else
    fail "CLI --check unexpected return codes (block=$check_block_rc allow=$check_allow_rc admin=$check_admin_rc)"
fi

audit_rc=0
audit_json=$(HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash "$CLI_SRC" --audit --json 2>&1) || audit_rc=$?
if [ "$audit_rc" -eq 2 ] && \
   printf '%s' "$audit_json" | grep -q '"external_count": 4' && \
   printf '%s' "$audit_json" | grep -q 'ext-fwd@gmail.com' && \
   printf '%s' "$audit_json" | grep -q 'ext-ca@outlook.com' && \
   printf '%s' "$audit_json" | grep -q 'dotfwd@gmail.com' && \
   printf '%s' "$audit_json" | grep -q 'sieve-ext@yahoo.com'; then
    pass "CLI --audit detects external account forwards, catch-alls, .forward, and Sieve redirects (ignoring :blackhole: and internal)"
else
    fail "CLI --audit failed (rc=$audit_rc): $audit_json"
fi

# Verify S67 check inside scripts/security-audit/lib/system/mail.sh
S67_SCRIPT="$TEST_ROOT/s67.sh"
cat > "$S67_SCRIPT" << EOF
is_service_active() { [ "\$1" = "exim4" ]; }
command_exists() { return 1; }
hestia_user_list() { printf 'admin\nuser1\nuser2\n'; }
section() { :; }
result_pass() { printf 'PASS:%s:%s\n' "\$1" "\$2"; }
result_warn() { printf 'WARN:%s:%s\n' "\$1" "\$2"; }
result_fail() { printf 'FAIL:%s:%s\n' "\$1" "\$2"; }
result_info() { printf 'INFO:%s:%s\n' "\$1" "\$2"; }
result_skip() { printf 'SKIP:%s:%s\n' "\$1" "\$2"; }
result_critical() { printf 'CRIT:%s:%s\n' "\$1" "\$2"; }
EOF
cat "$REPO_ROOT/scripts/security-audit/lib/system/mail.sh" >> "$S67_SCRIPT"

s67_warn=$(HESTIA="$HESTIA_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash -c "source '$S67_SCRIPT'; check_mail" 2>&1)
if printf '%s\n' "$s67_warn" | grep -q '^WARN:S67:Found 2 external mail forward/catch-all'; then
    pass "v-security-audit S67 warns on active external forward + external catch-all"
else
    fail "v-security-audit S67 did not warn as expected: $s67_warn"
fi

cat > "$HESTIA_FIX/data/users/user1/mail.conf" << 'EOF'
DOMAIN='user1.example' CATCHALL='' SUSPENDED='no'
EOF
cat > "$HESTIA_FIX/data/users/user1/mail/user1.example.conf" << 'EOF'
ACCOUNT='sales' FWD='info@user1.example,:blackhole:' FWD_ONLY='yes' SUSPENDED='no'
EOF
s67_pass=$(HESTIA="$HESTIA_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash -c "source '$S67_SCRIPT'; check_mail" 2>&1)
if printf '%s\n' "$s67_pass" | grep -q '^PASS:S67:No external mail forwards or external catch-all redirects found'; then
    pass "v-security-audit S67 passes when only internal forwards and :blackhole: exist"
else
    fail "v-security-audit S67 did not pass cleanly: $s67_pass"
fi

echo ""
echo "================================================================="
echo " Mail Forward Policy Summary: $PASS_COUNT PASSED, $FAIL_COUNT FAILED"
echo "================================================================="
[ "$FAIL_COUNT" -eq 0 ]
