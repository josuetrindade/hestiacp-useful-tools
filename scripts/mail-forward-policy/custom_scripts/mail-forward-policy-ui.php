<?php

declare(strict_types=1);

// Prevent direct HTTP execution under /js/custom_scripts/
if (!defined("HESTIA_DIR_BIN")) {
	http_response_code(404);
	exit();
}

// Show guidance only for non-admin sessions on Mail add/edit pages.
if (($_SESSION["userContext"] ?? "") === "admin") {
	return;
}

$hst_mfp_req_path = parse_url((string) ($_SERVER["REQUEST_URI"] ?? "/"), PHP_URL_PATH) ?: "/";
if (
	!str_starts_with($hst_mfp_req_path, "/add/mail/") &&
	!str_starts_with($hst_mfp_req_path, "/edit/mail/")
) {
	unset($hst_mfp_req_path);
	return;
}

$hst_mfp_inc = dirname(__DIR__, 2) . "/inc/mail_forward_policy.php";
if (!is_file($hst_mfp_inc)) {
	unset($hst_mfp_req_path, $hst_mfp_inc);
	return;
}
require_once $hst_mfp_inc;

if (!function_exists("hst_mfp_load_config")) {
	unset($hst_mfp_req_path, $hst_mfp_inc);
	return;
}

$hst_mfp_cfg = hst_mfp_load_config();
if (empty($hst_mfp_cfg["enabled"]) || empty($hst_mfp_cfg["enable_ui_hint"])) {
	unset($hst_mfp_req_path, $hst_mfp_inc, $hst_mfp_cfg);
	return;
}

$hst_mfp_has_gettext = function_exists("_");
$hst_mfp_is_server_scope = ($hst_mfp_cfg["scope"] ?? "user") === "server";

$hst_mfp_fwd_hint = $hst_mfp_is_server_scope
	? ($hst_mfp_has_gettext
		? _(
			"Server policy: forwarding is restricted to mail domains hosted on this server. To read mail in Gmail, Outlook, or mobile apps, connect via IMAP/SMTP using the settings panel.",
		)
		: "Server policy: forwarding is restricted to mail domains hosted on this server. To read mail in Gmail, Outlook, or mobile apps, connect via IMAP/SMTP using the settings panel.")
	: ($hst_mfp_has_gettext
		? _(
			"Server policy: forwarding is restricted to your own mail domains. To read mail in Gmail, Outlook, or mobile apps, connect via IMAP/SMTP using the settings panel.",
		)
		: "Server policy: forwarding is restricted to your own mail domains. To read mail in Gmail, Outlook, or mobile apps, connect via IMAP/SMTP using the settings panel.");
$hst_mfp_catchall_hint = $hst_mfp_has_gettext
	? _(
		"Server policy: external addresses are not allowed for Catch-All. Use an internal mailbox or contact the administrator.",
	)
	: "Server policy: external addresses are not allowed for Catch-All. Use an internal mailbox or contact the administrator.";

$hst_mfp_payload = json_encode(
	[
		"fwdHint" => $hst_mfp_fwd_hint,
		"catchallHint" => !empty($hst_mfp_cfg["block_catchall"]) ? $hst_mfp_catchall_hint : "",
	],
	JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT,
);

if (is_string($hst_mfp_payload)) {
	echo "<script>\n";
	echo "document.addEventListener('DOMContentLoaded', function () {\n";
	echo "  var cfg = " . $hst_mfp_payload . ";\n";
	echo "  function addHint(el, text) {\n";
	echo "    if (!el || !text || !el.parentElement) return;\n";
	echo "    if (el.parentElement.querySelector('[data-mfp-hint]')) return;\n";
	echo "    var p = document.createElement('p');\n";
	echo "    p.className = 'hint u-mt5';\n";
	echo "    p.setAttribute('data-mfp-hint', '1');\n";
	echo "    p.textContent = text;\n";
	echo "    el.insertAdjacentElement('afterend', p);\n";
	echo "  }\n";
	echo "  addHint(document.getElementById('v_fwd'), cfg.fwdHint);\n";
	echo "  addHint(document.getElementById('v_catchall'), cfg.catchallHint);\n";
	echo "});\n";
	echo "</script>\n";
}

unset(
	$hst_mfp_req_path,
	$hst_mfp_inc,
	$hst_mfp_cfg,
	$hst_mfp_has_gettext,
	$hst_mfp_is_server_scope,
	$hst_mfp_fwd_hint,
	$hst_mfp_catchall_hint,
	$hst_mfp_payload,
);
