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
SAFE_REPO_ROOT=""
cleanup() {
    rm -rf "$TEST_ROOT"
    [ -n "$SAFE_REPO_ROOT" ] && rm -rf "$SAFE_REPO_ROOT"
}
trap cleanup EXIT

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
	// Delete antispam
	if (empty($_SESSION["error_msg"])) {
		$antispam_changed = true;
	}
	// Change catchall address
	if (!empty($v_catchall) && !empty($_POST["v_catchall"]) && empty($_SESSION["error_msg"])) {
		echo "CA_CHANGED\n";
	}
}
if (!empty($_POST["save"]) && !empty($_GET["account"])) {
	// Change password
	if (!empty($_POST["v_password"]) && empty($_SESSION["error_msg"])) {
		echo "PASS_CHANGED\n";
	}
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
    user1) echo '{"user1.example": {"SUSPENDED": "no"}, "susp.example": {"SUSPENDED": "yes"}}' ;;
    user2) echo '{"user2.example": {"SUSPENDED": "no"}}' ;;
    *)     echo '{}' ;;
esac
EOF
cat > "$MOCK_BIN/v-list-users" << 'EOF'
#!/bin/bash
echo '{"admin": {}, "user1": {}, "user2": {}}'
EOF
cat > "$MOCK_BIN/v-list-user" << 'EOF'
#!/bin/bash
u="$1"
case "$u" in
    admin|secadmin) echo "{\"$u\": {\"ROLE\": \"admin\"}}" ;;
    *)              echo "{\"$u\": {\"ROLE\": \"user\"}}" ;;
esac
EOF
chmod +x "$MOCK_BIN/v-list-mail-domains" "$MOCK_BIN/v-list-users" "$MOCK_BIN/v-list-user"

mkdir -p "$EXIM_FIX/susp.example"

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

// F) Existing admin-set external forward preserved only when exact, blocked on case variant or new external
putenv("HESTIA_MFP_CONF=$conf_user");
$existing = ["vip@gmail.com", "local@user1.example"];
$posted_keep = hst_mfp_parse_targets("vip@gmail.com\nlocal@user1.example");
$added_keep = array_values(array_diff($posted_keep, $existing));
assert_case("keeping existing external fwd allowed", hst_mfp_validate_web_forwards($added_keep, "user1", "forward"), true);
$posted_case = hst_mfp_parse_targets("VIP@GMAIL.COM\nlocal@user1.example");
$added_case = array_values(array_diff($posted_case, $existing));
assert_case("case-variant on existing external fwd blocked", hst_mfp_validate_web_forwards($added_case, "user1", "forward"), false);
$posted_add = hst_mfp_parse_targets("vip@gmail.com, another@gmail.com");
$added_new = array_values(array_diff($posted_add, $existing));
assert_case("adding extra external fwd blocked", hst_mfp_validate_web_forwards($added_new, "user1", "forward"), false);

// G) API command checks (including positional gap-shift, invalid user, extra FORCE arg & fail-closed)
assert_case("API external fwd blocked for user1", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg4" => "lazy@gmail.com"], "user1", "admin"), false);
assert_case("API external catchall blocked for user1", hst_mfp_validate_api_command("v-add-mail-domain-catchall", ["arg1" => "user1", "arg3" => "lazy@gmail.com"], "user1", "admin"), false);
assert_case("API positional gap-shift fwd (no arg4, arg5=gmail) blocked", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg2" => "user1.example", "arg3" => "sales", "arg5" => "evil@gmail.com"], "user1", "admin"), false);
assert_case("API positional gap-shift catchall (no arg3, arg4=gmail) blocked", hst_mfp_validate_api_command("v-add-mail-domain-catchall", ["arg1" => "user1", "arg2" => "user1.example", "arg4" => "evil@gmail.com"], "user1", "admin"), false);
assert_case("API empty target fails closed", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg2" => "user1.example", "arg3" => "sales"], "user1", "admin"), false);
assert_case("API trailing extra FORCE arg blocked", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg2" => "user1.example", "arg3" => "sales", "arg4" => "info@user1.example", "arg5" => "yes"], "user1", "admin"), false);
assert_case("API invalid username fails closed", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg4" => "info@user1.example"], "../evil", "admin"), false);
assert_case("API own fwd allowed for user1", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg2" => "user1.example", "arg3" => "sales", "arg4" => "info@user1.example"], "user1", "admin"), true);
assert_case("API blackhole allowed for user1", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg2" => "user1.example", "arg3" => "sales", "arg4" => ":blackhole:"], "user1", "admin"), true);
assert_case("API blackhole blocked for catchall", hst_mfp_validate_web_forwards([":blackhole:"], "user1", "catchall"), false);
assert_case("API external allowed for secadmin", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg4" => "lazy@gmail.com"], "secadmin", "admin"), true);
assert_case("API external allowed for root_user", hst_mfp_validate_api_command("v-add-mail-account-forward", ["arg1" => "user1", "arg4" => "lazy@gmail.com"], "admin", "admin"), true);

// H) Suspended mail domain blocked in BOTH user and server scope, even if EXIM_DOMAINS_DIR exists (#H3/#T2)
assert_case("suspended mail domain blocked (user scope)", hst_mfp_validate_web_forwards(["sales@susp.example"], "user1", "forward"), false);
putenv("HESTIA_MFP_CONF=$conf_server");
assert_case("suspended mail domain blocked (server scope)", hst_mfp_validate_web_forwards(["sales@susp.example"], "user1", "forward"), false);
putenv("HESTIA_MFP_CONF=$conf_user");

// I) Malformed ENABLED fails closed (#T2)
$conf_typo = $argv[4] . "/conf_typo.conf";
file_put_contents($conf_typo, "ENABLED=\"truee\"\nSCOPE=\"user\"\n");
$typo_cfg = hst_mfp_load_config($conf_typo);
if ($typo_cfg["enabled"] !== true) {
    fwrite(STDERR, "FAIL: malformed ENABLED failed open\n");
    exit(1);
}

echo "ALL_PHP_CASES_OK\n";
' "$MOCK_BIN" "$EXIM_FIX" "$HELPER_SRC" "$TEST_ROOT" 2>&1)
if printf '%s\n' "$php_test_out" | grep -q 'ALL_PHP_CASES_OK'; then
    pass "All PHP web/API policy cases passed (incl. positional gap-shift & suspended domain fixes)"
else
    fail "PHP functional policy test failed: $php_test_out"
fi

# 4b. Red-Team Regression #3/#7/#9: Patched edit/mail/index.php runtime execution (cross-account clone, case bypass, array input, atomic abort)
edit_rt_out=$(php -d error_reporting=E_ALL -r '
define("HESTIA_DIR_BIN", $argv[1] . "/");
define("HESTIA_MFP_TEST_MODE", true);
define("HESTIA_MFP_SKIP_LOG", true);
define("HESTIA_MFP_CMD_PREFIX", $argv[1] . "/");
define("HESTIA_MFP_CONF", $argv[2] . "/conf_user.conf");
if (!function_exists("_")) { function _(string $s): string { return $s; } }

// Case A: Cross-account exception cloning (GET=direcao, POST v_account=comercial, v_fwd=vip@gmail.com)
$_SESSION = ["userContext" => "user", "error_msg" => ""];
$_GET = ["domain" => "user1.example", "account" => "direcao"];
$_POST = ["save" => "save", "v_account" => "comercial", "v_password" => "Secret123", "v_fwd" => "vip@gmail.com"];
$v_domain = "user1.example";
$v_account = "comercial";
$vfwd = ["vip@gmail.com"]; // stale GET account value!
$data = ["direcao" => ["FWD" => "vip@gmail.com"], "comercial" => ["FWD" => ""]];
ob_start(); include $argv[3]; $out_a = ob_get_clean();
$pass_a = ($out_a === "" && !empty($_SESSION["error_msg"]));

// Case B: Case-variant forward on same account (existing=vip@gmail.com, posted=VIP@GMAIL.COM)
$_SESSION = ["userContext" => "user", "error_msg" => ""];
$_GET = ["domain" => "user1.example", "account" => "direcao"];
$_POST = ["save" => "save", "v_account" => "direcao", "v_password" => "Secret123", "v_fwd" => "VIP@GMAIL.COM"];
$v_account = "direcao";
$vfwd = ["vip@gmail.com"];
$data = ["direcao" => ["FWD" => "vip@gmail.com"]];
ob_start(); include $argv[3]; $out_b = ob_get_clean();
$pass_b = ($out_b === "" && !empty($_SESSION["error_msg"]));

// Case C: Legitimate password change keeping admin-set vip@gmail.com exact -> PASS & updates password
$_SESSION = ["userContext" => "user", "error_msg" => ""];
$_GET = ["domain" => "user1.example", "account" => "direcao"];
$_POST = ["save" => "save", "v_account" => "direcao", "v_password" => "Secret123", "v_fwd" => "vip@gmail.com"];
$v_account = "direcao";
$vfwd = ["vip@gmail.com"];
$data = ["direcao" => ["FWD" => "vip@gmail.com"]];
ob_start(); include $argv[3]; $out_c = ob_get_clean();
$pass_c = (str_contains($out_c, "PASS_CHANGED") && empty($_SESSION["error_msg"]));

// Case D: Array POST payload v_fwd[] fails closed cleanly with zero warnings
$_SESSION = ["userContext" => "user", "error_msg" => ""];
$_POST = ["save" => "save", "v_account" => "comercial", "v_fwd" => ["evil@gmail.com"]];
$v_account = "comercial";
$data = ["comercial" => ["FWD" => ""]];
ob_start(); include $argv[3]; $out_d = ob_get_clean();
$pass_d = ($out_d === "" && !empty($_SESSION["error_msg"]));

echo ($pass_a && $pass_b && $pass_c && $pass_d) ? "EDIT_REDTEAM_OK\n" : "FAIL a=$pass_a b=$pass_b c=$pass_c d=$pass_d out_a=$out_a out_b=$out_b out_c=$out_c\n";
' "$MOCK_BIN" "$TEST_ROOT" "$HESTIA_FIX/web/edit/mail/index.php" 2>&1)
if [ "$edit_rt_out" = "EDIT_REDTEAM_OK" ]; then
    pass "Patched edit/mail/index.php blocks cross-account cloning, case variants, array payloads, and prevents partial saves"
else
    fail "edit/mail/index.php red-team harness failed: $edit_rt_out"
fi

# 4c. Red-Team #5: Unreadable existing config (0600 root:root) must fail closed for hestiaweb / non-root
cat > "$TEST_ROOT/locked.conf" << 'EOF'
ENABLED="yes"
SCOPE="server"
EOF
chmod 0600 "$TEST_ROOT/locked.conf"
if [ "$(id -u)" -eq 0 ] && id www-data >/dev/null 2>&1; then
    chmod 0755 "$TEST_ROOT"
    fc_out=$(su -s /bin/sh www-data -c "php -r '
define(\"HESTIA_MFP_TEST_MODE\", true);
define(\"HESTIA_MFP_SILENCE_ERROR_LOG\", true);
define(\"HESTIA_MFP_CONF\", \$argv[1]);
require_once \$argv[2];
\$c = hst_mfp_load_config();
echo (\$c[\"enabled\"] === true && \$c[\"scope\"] === \"user\") ? \"FAIL_CLOSED_OK\n\" : \"FAIL_OPEN\n\";
' '$TEST_ROOT/locked.conf' '$HELPER_SRC'")
    if [ "$fc_out" = "FAIL_CLOSED_OK" ]; then
        pass "Unreadable existing config file (0600) fails closed as www-data (enabled=true, scope=user)"
    else
        fail "Unreadable existing config did not fail closed: $fc_out"
    fi
else
    fc_out=$(php -r '
define("HESTIA_MFP_TEST_MODE", true);
define("HESTIA_MFP_SILENCE_ERROR_LOG", true);
define("HESTIA_MFP_CONF", $argv[1]);
require_once $argv[2];
$c = hst_mfp_load_config();
echo ($c["enabled"] === true && $c["scope"] === "user") ? "FAIL_CLOSED_OK\n" : "FAIL_OPEN\n";
' "$TEST_ROOT/locked.conf" "$HELPER_SRC")
    if [ "$fc_out" = "FAIL_CLOSED_OK" ]; then
        pass "Unreadable existing config fails closed (enabled=true, scope=user)"
    else
        fail "Unreadable existing config did not fail closed: $fc_out"
    fi
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
# Symlink / device DoS traps (#4): must be safely ignored by --audit (never open /dev/zero or leak /etc/passwd)
ln -s /dev/zero "$HOME_FIX/user1/mail/user1.example/sales/sieve/dos.sieve"
ln -s /etc/passwd "$HOME_FIX/user1/.forward"

check_block_rc=0
HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash "$CLI_SRC" --check user1 lazy@gmail.com >/dev/null 2>&1 || check_block_rc=$?
check_allow_rc=0
HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash "$CLI_SRC" --check user1 info@user1.example >/dev/null 2>&1 || check_allow_rc=$?
check_admin_rc=0
HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash "$CLI_SRC" --check admin lazy@gmail.com >/dev/null 2>&1 || check_admin_rc=$?
check_trav_rc=0
HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash "$CLI_SRC" --check ../../etc/passwd lazy@gmail.com >/dev/null 2>&1 || check_trav_rc=$?
if [ "$check_block_rc" -eq 1 ] && [ "$check_allow_rc" -eq 0 ] && [ "$check_admin_rc" -eq 0 ] && [ "$check_trav_rc" -eq 1 ]; then
    pass "CLI --check handles blocked=1, own/admin=0, and rejects path-traversal usernames (#4)"
else
    fail "CLI --check unexpected return codes (block=$check_block_rc allow=$check_allow_rc admin=$check_admin_rc trav=$check_trav_rc)"
fi

audit_rc=0
audit_json=$(HESTIA="$HESTIA_FIX" MFP_CONF="$CONF_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash "$CLI_SRC" --audit --json 2>&1) || audit_rc=$?
if [ "$audit_rc" -eq 2 ] && \
   printf '%s' "$audit_json" | grep -q '"external_count": 4' && \
   printf '%s' "$audit_json" | grep -q 'ext-fwd@gmail.com' && \
   printf '%s' "$audit_json" | grep -q 'ext-ca@outlook.com' && \
   printf '%s' "$audit_json" | grep -q 'dotfwd@gmail.com' && \
   printf '%s' "$audit_json" | grep -q 'sieve-ext@yahoo.com'; then
    pass "CLI --audit detects external targets while safely skipping /dev/zero and /etc/passwd symlinks (#4)"
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

s67_warn=$(HESTIA="$HESTIA_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash -uc "set -uo pipefail; source '$S67_SCRIPT'; check_mail; command_exists() { [ \"\$1\" = \"dig\" ]; }; dig() { printf 'v=DMARC1\n'; }; check_dns_mail_advanced" 2>&1)
if printf '%s\n' "$s67_warn" | grep -q '^WARN:S67:Found 4 external mail forward/catch-all' && \
   printf '%s\n' "$s67_warn" | grep -q ', ' && \
   printf '%s\n' "$s67_warn" | grep -q '^PASS:S59:DMARC configured'; then
    pass "v-security-audit S67 & S59 pass under set -uo pipefail and S67 warns with comma-space samples"
else
    fail "v-security-audit S67/S59 failed under set -uo pipefail: $s67_warn"
fi

rm -f "$HOME_FIX/user2/.forward" "$HOME_FIX/user1/mail/user1.example/sales/sieve/custom.sieve"
cat > "$HESTIA_FIX/data/users/user1/mail.conf" << 'EOF'
DOMAIN='user1.example' CATCHALL='' SUSPENDED='no'
EOF
cat > "$HESTIA_FIX/data/users/user1/mail/user1.example.conf" << 'EOF'
ACCOUNT='sales' FWD='info@user1.example,:blackhole:' FWD_ONLY='yes' SUSPENDED='no'
EOF
s67_pass=$(HESTIA="$HESTIA_FIX" HESTIA_HOME_ROOT="$HOME_FIX" EXIM_DOMAINS_DIR="$EXIM_FIX" bash -uc "set -uo pipefail; source '$S67_SCRIPT'; check_mail" 2>&1)
if printf '%s\n' "$s67_pass" | grep -q '^PASS:S67:No external mail forwards or external catch-all redirects found'; then
    pass "v-security-audit S67 passes when only internal forwards and :blackhole: exist (and ignores symlinks)"
else
    fail "v-security-audit S67 did not pass cleanly: $s67_pass"
fi

# 6. CLI flag parsing & end-to-end installer / APT hook / version-gate tests
help_out=$(bash "$REPO_ROOT/install.sh" --help 2>&1)
mod_help_out=$(bash "$REPO_ROOT/scripts/mail-forward-policy/install.sh" --help 2>&1)
bad_combo_rc=0
bash "$REPO_ROOT/install.sh" --mail-forward-policy --all >/dev/null 2>&1 || bad_combo_rc=$?
bad_mod_rc=0
bash "$REPO_ROOT/scripts/mail-forward-policy/install.sh" --no-such-flag >/dev/null 2>&1 || bad_mod_rc=$?
if printf '%s' "$help_out" | grep -q -- '--mail-forward-policy' && \
   printf '%s' "$mod_help_out" | grep -q -- '--allow-untested-hestia' && \
   [ "$bad_combo_rc" -ne 0 ] && [ "$bad_mod_rc" -ne 0 ]; then
    pass "Top-level and module installers expose expected flags and reject invalid flag combinations"
else
    fail "Installer CLI flag validation failed (combo=$bad_combo_rc mod=$bad_mod_rc)"
fi

if [ "$(id -u)" -eq 0 ]; then
    # Shared apt-hook lib must be bash -n clean too
    if bash -n "$REPO_ROOT/scripts/lib/apt-hook.sh"; then
        pass "scripts/lib/apt-hook.sh passes bash -n"
    else
        fail "scripts/lib/apt-hook.sh failed bash -n"
    fi

    SAFE_BASE="/run"
    [ -d "$SAFE_BASE" ] && [ -w "$SAFE_BASE" ] || SAFE_BASE="/var/lock"
    SAFE_REPO_ROOT=$(mktemp -d "${SAFE_BASE}/mfp-repo.XXXXXX")
    chmod 0755 "$SAFE_REPO_ROOT"
    mkdir -p "$SAFE_REPO_ROOT/scripts/lib" "$SAFE_REPO_ROOT/scripts/mail-forward-policy"
    cp "$REPO_ROOT/install.sh" "$SAFE_REPO_ROOT/install.sh"
    cp -r "$REPO_ROOT/scripts/lib/." "$SAFE_REPO_ROOT/scripts/lib/"
    cp -r "$REPO_ROOT/scripts/mail-forward-policy/." "$SAFE_REPO_ROOT/scripts/mail-forward-policy/"
    chown -R root:root "$SAFE_REPO_ROOT"
    chmod -R u+rwX,go-w "$SAFE_REPO_ROOT"
    find "$SAFE_REPO_ROOT" -type l -delete

    INST_HESTIA="$TEST_ROOT/inst_hestia"
    INST_CONF="$TEST_ROOT/etc/hestiacp-mail-forward-policy.conf"
    INST_APT="$TEST_ROOT/apt.conf.d"
    INST_BAK="$TEST_ROOT/inst_bak"
    INST_STATE="$TEST_ROOT/inst_state"
    mkdir -p "$INST_HESTIA/bin" "$INST_HESTIA/conf" "$INST_HESTIA/web/add/mail" "$INST_HESTIA/web/edit/mail" "$INST_HESTIA/web/api" \
             "$INST_HESTIA/web/inc" "$INST_HESTIA/web/js/custom_scripts" "$TEST_ROOT/etc" "$INST_APT" "$INST_BAK" "$INST_STATE"

    cp "$TEST_ROOT/orig_add.php" "$INST_HESTIA/web/add/mail/index.php"
    cp "$TEST_ROOT/orig_edit.php" "$INST_HESTIA/web/edit/mail/index.php"
    cp "$TEST_ROOT/orig_api.php" "$INST_HESTIA/web/api/index.php"
    printf "VERSION='1.10.10'\n" > "$INST_HESTIA/conf/hestia.conf"

    # 6a. Fresh standalone module install creates 0644 config, patches core files, and installs standalone APT hook
    if HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" MFP_BAK_DIR="$INST_BAK" \
       bash "$SAFE_REPO_ROOT/scripts/mail-forward-policy/install.sh" >/dev/null 2>&1 && \
       [ "$(stat -c '%a' "$INST_HESTIA/bin/v-mail-forward-policy")" = "755" ] && \
       [ "$(stat -c '%a' "$INST_CONF")" = "644" ] && \
       grep -q '^ENABLED="yes"' "$INST_CONF" && \
       grep -q '^SCOPE="user"' "$INST_CONF" && \
       [ "$(stat -c '%a' "$INST_HESTIA/web/inc/mail_forward_policy.php")" = "644" ] && \
       [ "$(stat -c '%a' "$INST_HESTIA/web/js/custom_scripts/mail-forward-policy-ui.php")" = "644" ] && \
       php -l "$INST_HESTIA/web/add/mail/index.php" >/dev/null 2>&1 && \
       php -l "$INST_HESTIA/web/edit/mail/index.php" >/dev/null 2>&1 && \
       php -l "$INST_HESTIA/web/api/index.php" >/dev/null 2>&1 && \
       HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" "$INST_HESTIA/bin/v-mail-forward-policy" --status >/dev/null 2>&1 && \
       [ -f "$INST_APT/99hestia-mail-forward-policy" ] && \
       [ "$(stat -c '%a' "$INST_APT/99hestia-mail-forward-policy")" = "644" ] && \
       grep -q -- '--mail-forward-policy --apt-hook' "$INST_APT/99hestia-mail-forward-policy"; then
        pass "Standalone install.sh deploys CLI/config/helpers, passes --status, and installs standalone APT hook"
    else
        fail "Standalone module install.sh verification failed"
    fi

    # 6b. Re-run preserves customized config and heals 0600 permission drift back to 0644
    printf 'ENABLED="yes"\nSCOPE="server"\nALLOWLIST_DOMAINS="partner.example"\n' > "$INST_CONF"
    chmod 0600 "$INST_CONF"
    if HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" MFP_BAK_DIR="$INST_BAK" \
       bash "$SAFE_REPO_ROOT/scripts/mail-forward-policy/install.sh" >/dev/null 2>&1 && \
       [ "$(stat -c '%a' "$INST_CONF")" = "644" ] && \
       grep -q '^SCOPE="server"' "$INST_CONF" && \
       grep -q '^ALLOWLIST_DOMAINS="partner.example"' "$INST_CONF"; then
        pass "Installer re-run preserves customized config values and heals 0600 mode back to 0644"
    else
        fail "Installer re-run failed to preserve config or heal 0644 mode"
    fi

    # 6c. --disable cleans up standalone APT hook and restores core PHP byte-for-byte while preserving config
    if HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" MFP_BAK_DIR="$INST_BAK" \
       "$INST_HESTIA/bin/v-mail-forward-policy" --disable >/dev/null 2>&1 && \
       [ ! -e "$INST_APT/99hestia-mail-forward-policy" ] && \
       [ -f "$INST_CONF" ] && \
       cmp -s "$TEST_ROOT/orig_add.php" "$INST_HESTIA/web/add/mail/index.php" && \
       cmp -s "$TEST_ROOT/orig_edit.php" "$INST_HESTIA/web/edit/mail/index.php" && \
       cmp -s "$TEST_ROOT/orig_api.php" "$INST_HESTIA/web/api/index.php"; then
        pass "--disable removes standalone APT hook, restores core PHP byte-for-byte, and preserves config"
    else
        fail "--disable standalone cleanup failed"
    fi

    # 6d. Coexistence: when 99hestia-custom-patches is present, standalone hook is omitted and full hook kept untouched
    printf '// full-toolkit\n' > "$INST_APT/99hestia-custom-patches"
    if HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" MFP_BAK_DIR="$INST_BAK" \
       bash "$SAFE_REPO_ROOT/scripts/mail-forward-policy/install.sh" >/dev/null 2>&1 && \
       [ ! -e "$INST_APT/99hestia-mail-forward-policy" ] && \
       [ "$(cat "$INST_APT/99hestia-custom-patches")" = "// full-toolkit" ]; then
        pass "Installer avoids duplicate APT hook when 99hestia-custom-patches is already active"
    else
        fail "Installer did not defer cleanly to existing 99hestia-custom-patches"
    fi
    rm -f "$INST_APT/99hestia-custom-patches"

    # 6e. Version-gate enforcement via top-level install.sh --mail-forward-policy
    HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" MFP_BAK_DIR="$INST_BAK" \
        "$INST_HESTIA/bin/v-mail-forward-policy" --disable >/dev/null 2>&1
    printf "VERSION='1.99.0'\n" > "$INST_HESTIA/conf/hestia.conf"

    vg_manual_rc=0
    HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" MFP_BAK_DIR="$INST_BAK" \
    HESTIA_TOOLS_CONF="$TEST_ROOT/no-tools.conf" HESTIA_TOOLS_STATE_DIR="$INST_STATE" \
    HESTIA_TOOLS_HOLD_FILE="$INST_STATE/hestia-tools-version-hold.state" HESTIA_TOOLS_VERSION_LOG="$INST_STATE/version.log" \
        bash "$SAFE_REPO_ROOT/install.sh" --mail-forward-policy >/dev/null 2>&1 || vg_manual_rc=$?

    vg_apt_rc=0
    HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" MFP_BAK_DIR="$INST_BAK" \
    HESTIA_TOOLS_CONF="$TEST_ROOT/no-tools.conf" HESTIA_TOOLS_STATE_DIR="$INST_STATE" \
    HESTIA_TOOLS_HOLD_FILE="$INST_STATE/hestia-tools-version-hold.state" HESTIA_TOOLS_VERSION_LOG="$INST_STATE/version.log" \
        bash "$SAFE_REPO_ROOT/install.sh" --mail-forward-policy --apt-hook >/dev/null 2>&1 || vg_apt_rc=$?

    if [ "$vg_manual_rc" -ne 0 ] && [ "$vg_apt_rc" -eq 0 ] && \
       ! grep -q "hestia-mail-forward-policy" "$INST_HESTIA/web/add/mail/index.php" && \
       [ ! -f "$INST_HESTIA/web/inc/mail_forward_policy.php" ] && \
       [ -x "$INST_HESTIA/bin/v-mail-forward-policy" ] && \
       grep -q "^held_version=1.99.0$" "$INST_STATE/hestia-tools-version-hold.state"; then
        pass "Top-level install.sh --mail-forward-policy enforces version gate on manual and --apt-hook runs without overwriting helper/UI"
    else
        fail "Version-gate enforcement failed (manual_rc=$vg_manual_rc apt_rc=$vg_apt_rc)"
    fi

    # 6f. HIGH-T1: Native HestiaCP 1.11.0+ helper is preserved under hold & obsolete UI script is removed cleanly
    printf '<?php\nfunction hst_validate_mail_forward_policy() { return null; }\n' > "$INST_HESTIA/web/inc/mail_forward_policy.php"
    cp "$UI_SRC" "$INST_HESTIA/web/js/custom_scripts/mail-forward-policy-ui.php"
    ui_nat_out=$(HESTIA_DIR_BIN="$INST_HESTIA/bin/" php -r 'define("HESTIA_DIR_BIN", $argv[1]); $_SERVER["REQUEST_URI"]="/add/mail/"; $_SESSION=["userContext"=>"user"]; include $argv[2];' "$INST_HESTIA/bin/" "$INST_HESTIA/web/js/custom_scripts/mail-forward-policy-ui.php" 2>&1 || true)
    if HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" MFP_BAK_DIR="$INST_BAK" \
       HESTIA_TOOLS_CONF="$TEST_ROOT/no-tools.conf" HESTIA_TOOLS_STATE_DIR="$INST_STATE" \
       HESTIA_TOOLS_HOLD_FILE="$INST_STATE/hestia-tools-version-hold.state" HESTIA_TOOLS_VERSION_LOG="$INST_STATE/version.log" \
       bash "$SAFE_REPO_ROOT/install.sh" --mail-forward-policy --apt-hook >/dev/null 2>&1 && \
       grep -q "hst_validate_mail_forward_policy" "$INST_HESTIA/web/inc/mail_forward_policy.php" && \
       [ ! -e "$INST_HESTIA/web/js/custom_scripts/mail-forward-policy-ui.php" ] && \
       [ -z "$ui_nat_out" ]; then
        pass "HIGH-T1: Native 1.11.0+ helper is preserved across --apt-hook hold and obsolete UI hint is removed safely"
    else
        fail "HIGH-T1 native upgrade preservation check failed (ui_nat_out=$ui_nat_out)"
    fi
    rm -f "$INST_HESTIA/web/inc/mail_forward_policy.php"

    # 6g. Generated DPkg::Post-Invoke hook parses cleanly in apt-config (if present) and executes under /bin/sh -c
    apt_parse_ok=1
    if command -v apt-config >/dev/null 2>&1; then
        apt-config -c "$INST_APT/99hestia-mail-forward-policy" dump 2>/dev/null | grep -q 'DPkg::Post-Invoke' || apt_parse_ok=0
    fi
    hook_cmd=$(sed -n 's/^DPkg::Post-Invoke { "\(.*\)"; };$/\1/p' "$INST_APT/99hestia-mail-forward-policy" | sed 's/\\"/"/g')
    sh_rc=0
    /bin/sh -c "$hook_cmd" >/dev/null 2>&1 || sh_rc=$?
    if [ "$apt_parse_ok" -eq 1 ] && [ -n "$hook_cmd" ] && [ "$sh_rc" -eq 0 ]; then
        pass "MEDIUM-T3: Generated APT DPkg::Post-Invoke parses via apt-config and runs cleanly under /bin/sh -c"
    else
        fail "MEDIUM-T3: Generated APT hook failed (apt_parse_ok=$apt_parse_ok rc=$sh_rc)"
    fi

    # 6h. Missing helper fails closed in patched add/mail/index.php (#T2)
    if HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" MFP_BAK_DIR="$INST_BAK" \
       HESTIA_TOOLS_CONF="$TEST_ROOT/no-tools.conf" HESTIA_TOOLS_STATE_DIR="$INST_STATE" \
       HESTIA_TOOLS_HOLD_FILE="$INST_STATE/hestia-tools-version-hold.state" HESTIA_TOOLS_VERSION_LOG="$INST_STATE/version.log" \
       bash "$SAFE_REPO_ROOT/install.sh" --mail-forward-policy --allow-untested-hestia >/dev/null 2>&1 && \
       HESTIA="$INST_HESTIA" MFP_CONF="$INST_CONF" APT_CONF_DIR="$INST_APT" "$INST_HESTIA/bin/v-mail-forward-policy" --status >/dev/null 2>&1; then
        pass "Top-level install.sh --mail-forward-policy --allow-untested-hestia overrides pin cleanly"
    else
        fail "--allow-untested-hestia override failed for --mail-forward-policy"
    fi

    mv "$INST_HESTIA/web/inc/mail_forward_policy.php" "$INST_HESTIA/web/inc/mail_forward_policy.php.hidden"
    miss_out=$(php -r 'function _(string $s): string { return $s; } $_SESSION=["error_msg"=>""]; $_POST=["ok_acc"=>"1","v_fwd"=>"a@gmail.com"]; include $argv[1]; echo (!empty($_SESSION["error_msg"])) ? "FAIL_CLOSED" : "FAIL_OPEN";' "$INST_HESTIA/web/add/mail/index.php" 2>&1)
    mv "$INST_HESTIA/web/inc/mail_forward_policy.php.hidden" "$INST_HESTIA/web/inc/mail_forward_policy.php"
    if [ "$miss_out" = "FAIL_CLOSED" ]; then
        pass "Missing mail_forward_policy.php fails closed inside patched add/mail/index.php"
    else
        fail "Missing helper failed open in add/mail/index.php: $miss_out"
    fi
else
    pass "Skipped root-only installer sandbox tests (non-root user)"
fi

echo ""
echo "================================================================="
echo " Mail Forward Policy Summary: $PASS_COUNT PASSED, $FAIL_COUNT FAILED"
echo "================================================================="
[ "$FAIL_COUNT" -eq 0 ]
