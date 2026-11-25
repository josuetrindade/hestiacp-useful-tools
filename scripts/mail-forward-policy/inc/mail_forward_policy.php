<?php

declare(strict_types=1);

// Prevent direct web execution if served outside HestiaCP web entrypoints.
if (!defined("HESTIA_DIR_BIN") && !defined("HESTIA_MFP_TEST_MODE")) {
	http_response_code(404);
	exit();
}

/**
 * Resolve configuration file path (supports test overrides via constant or environment).
 */
function hst_mfp_config_path(): string {
	if (defined("HESTIA_MFP_CONF") && is_string(HESTIA_MFP_CONF) && HESTIA_MFP_CONF !== "") {
		return HESTIA_MFP_CONF;
	}
	$env = getenv("HESTIA_MFP_CONF");
	if (is_string($env) && $env !== "") {
		return $env;
	}
	return "/etc/hestiacp-mail-forward-policy.conf";
}

/**
 * Resolve Exim domains directory path for server-wide domain discovery.
 */
function hst_mfp_exim_domains_dir(): string {
	if (
		defined("HESTIA_MFP_EXIM_DOMAINS_DIR") &&
		is_string(HESTIA_MFP_EXIM_DOMAINS_DIR) &&
		HESTIA_MFP_EXIM_DOMAINS_DIR !== ""
	) {
		return HESTIA_MFP_EXIM_DOMAINS_DIR;
	}
	$env = getenv("HESTIA_MFP_EXIM_DOMAINS_DIR");
	if (is_string($env) && $env !== "") {
		return $env;
	}
	return "/etc/exim4/domains";
}

/**
 * Resolve HestiaCP command prefix (typically "/usr/bin/sudo /usr/local/hestia/bin/").
 */
function hst_mfp_cmd_prefix(): string {
	if (
		defined("HESTIA_MFP_CMD_PREFIX") &&
		is_string(HESTIA_MFP_CMD_PREFIX) &&
		HESTIA_MFP_CMD_PREFIX !== ""
	) {
		return HESTIA_MFP_CMD_PREFIX;
	}
	if (defined("HESTIA_CMD") && is_string(HESTIA_CMD) && HESTIA_CMD !== "") {
		return HESTIA_CMD;
	}
	return "/usr/bin/sudo /usr/local/hestia/bin/";
}

/**
 * Convert boolean-like config strings to bool.
 */
function hst_mfp_parse_bool(string $value, bool $default): bool {
	$norm = strtolower(trim($value));
	if (in_array($norm, ["yes", "true", "1", "on"], true)) {
		return true;
	}
	if (in_array($norm, ["no", "false", "0", "off"], true)) {
		return false;
	}
	return $default;
}

/**
 * Normalize a domain name to lowercase, without trailing dot, and IDNA-ASCII when available.
 */
function hst_mfp_normalize_domain(string $domain): string {
	$clean = strtolower(rtrim(trim($domain), "."));
	if ($clean === "" || preg_match('/[\s\x00-\x1f\x7f]/', $clean)) {
		return "";
	}
	if (preg_match('/[^\x20-\x7e]/', $clean) && function_exists("idn_to_ascii")) {
		$variant = defined("INTL_IDNA_VARIANT_UTS46") ? INTL_IDNA_VARIANT_UTS46 : 0;
		$ascii = @idn_to_ascii($clean, IDNA_DEFAULT, $variant);
		if (is_string($ascii) && $ascii !== "") {
			return strtolower($ascii);
		}
	}
	return $clean;
}

/**
 * Parse /etc/hestiacp-mail-forward-policy.conf safely without shell evaluation.
 * If the config file does not exist or cannot be read, fail closed with scope=user.
 *
 * @return array{
 *   enabled: bool,
 *   scope: string,
 *   block_catchall: bool,
 *   enforce_api: bool,
 *   enable_ui_hint: bool,
 *   allowlist_domains: array<string, true>
 * }
 */
function hst_mfp_load_config(?string $path = null): array {
	$defaults = [
		"enabled" => true,
		"scope" => "user",
		"block_catchall" => true,
		"enforce_api" => true,
		"enable_ui_hint" => true,
		"allowlist_domains" => [],
	];

	$conf_path = $path ?? hst_mfp_config_path();
	if (!file_exists($conf_path)) {
		return $defaults;
	}
	if (!is_file($conf_path) || !is_readable($conf_path)) {
		if (!defined("HESTIA_MFP_SILENCE_ERROR_LOG")) {
			error_log(
				"hestiacp-mail-forward-policy: config '$conf_path' exists but is not readable; failing closed with scope=user",
			);
		}
		$fail_closed = $defaults;
		$fail_closed["enabled"] = true;
		return $fail_closed;
	}

	$lines = @file($conf_path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
	if (!is_array($lines)) {
		if (!defined("HESTIA_MFP_SILENCE_ERROR_LOG")) {
			error_log(
				"hestiacp-mail-forward-policy: failed reading config '$conf_path'; failing closed with scope=user",
			);
		}
		$fail_closed = $defaults;
		$fail_closed["enabled"] = true;
		return $fail_closed;
	}

	$raw = [];
	foreach ($lines as $line) {
		$trimmed = trim($line);
		if ($trimmed === "" || str_starts_with($trimmed, "#")) {
			continue;
		}
		if (!preg_match('/^([A-Z0-9_]+)\s*=\s*(.*)$/', $trimmed, $m)) {
			continue;
		}
		$key = $m[1];
		$val = trim($m[2]);
		if (
			(str_starts_with($val, '"') && str_ends_with($val, '"') && strlen($val) >= 2) ||
			(str_starts_with($val, "'") && str_ends_with($val, "'") && strlen($val) >= 2)
		) {
			$val = substr($val, 1, -1);
		} else {
			// Strip inline comment only when unquoted and preceded by whitespace
			$val = preg_replace('/\s+#.*$/', "", $val) ?? $val;
			$val = trim($val);
		}
		$raw[$key] = $val;
	}

	$cfg = $defaults;
	$cfg["enabled"] = isset($raw["ENABLED"]) ? hst_mfp_parse_bool($raw["ENABLED"], true) : true;

	if (isset($raw["SCOPE"])) {
		$scope = strtolower(trim($raw["SCOPE"]));
		if ($scope === "server") {
			$cfg["scope"] = "server";
		} elseif ($scope === "user" || $scope === "no") {
			$cfg["scope"] = "user";
		}
	}

	if (isset($raw["BLOCK_CATCHALL"])) {
		$cfg["block_catchall"] = hst_mfp_parse_bool($raw["BLOCK_CATCHALL"], true);
	}
	if (isset($raw["ENFORCE_API"])) {
		$cfg["enforce_api"] = hst_mfp_parse_bool($raw["ENFORCE_API"], true);
	}
	if (isset($raw["ENABLE_UI_HINT"])) {
		$cfg["enable_ui_hint"] = hst_mfp_parse_bool($raw["ENABLE_UI_HINT"], true);
	}
	if (isset($raw["ALLOWLIST_DOMAINS"]) && trim($raw["ALLOWLIST_DOMAINS"]) !== "") {
		$parts = preg_split('/[\s,]+/', trim($raw["ALLOWLIST_DOMAINS"])) ?: [];
		foreach ($parts as $dom) {
			$norm = hst_mfp_normalize_domain($dom);
			if ($norm !== "") {
				$cfg["allowlist_domains"][$norm] = true;
			}
			$raw_lower = strtolower(rtrim(trim($dom), "."));
			if ($raw_lower !== "" && !preg_match('/[\s\x00-\x1f\x7f]/', $raw_lower)) {
				$cfg["allowlist_domains"][$raw_lower] = true;
			}
		}
	}

	return $cfg;
}

/**
 * Tokenize forwarder textarea input using the exact same splitting rules as HestiaCP.
 *
 * @return string[]
 */
function hst_mfp_parse_targets(string $raw): array {
	$clean = str_replace(["\r", "\n", ","], " ", $raw);
	$clean = preg_replace('/\s+/', " ", trim($clean)) ?? "";
	if ($clean === "") {
		return [];
	}
	$parts = explode(" ", $clean);
	$out = [];
	foreach ($parts as $part) {
		$item = trim($part);
		if ($item !== "") {
			$out[] = $item;
		}
	}
	return $out;
}

/**
 * Extract normalized domain part from a forwarding target.
 * Returns ":blackhole:" for Exim blackhole targets, or "" if the target is malformed.
 */
function hst_mfp_extract_domain(string $address): string {
	$trimmed = trim($address);
	if ($trimmed === "") {
		return "";
	}
	if (strtolower($trimmed) === ":blackhole:") {
		return ":blackhole:";
	}
	if (preg_match('/[\s\x00-\x1f\x7f\/|:]/', $trimmed)) {
		return "";
	}
	$parts = explode("@", $trimmed);
	if (count($parts) !== 2 || $parts[0] === "" || $parts[1] === "") {
		return "";
	}
	return hst_mfp_normalize_domain($parts[1]);
}

/**
 * Run a HestiaCP CLI JSON command and return decoded associative array, or empty array on error.
 *
 * @return array<string, mixed>
 */
function hst_mfp_exec_json(string $subcommand_with_args): array {
	$output = [];
	$rc = 0;
	exec(hst_mfp_cmd_prefix() . $subcommand_with_args, $output, $rc);
	if ($rc !== 0 || empty($output)) {
		return [];
	}
	$decoded = json_decode(implode("\n", $output), true);
	return is_array($decoded) ? $decoded : [];
}

/**
 * Add a domain name (and its IDNA-ASCII equivalent when non-ASCII) to the allowed domain set.
 *
 * @param array<string, true> $map
 */
function hst_mfp_add_domain_key(array &$map, string $domain): void {
	$trimmed = strtolower(rtrim(trim($domain), "."));
	if ($trimmed !== "" && !preg_match('/[\s\x00-\x1f\x7f]/', $trimmed)) {
		$map[$trimmed] = true;
	}
	$norm = hst_mfp_normalize_domain($domain);
	if ($norm !== "") {
		$map[$norm] = true;
	}
}

/**
 * Build allowed destination domain map for the target user and policy configuration.
 *
 * @return array<string, true>
 */
function hst_mfp_get_allowed_domains(string $target_user, array $cfg): array {
	$allowed = $cfg["allowlist_domains"] ?? [];
	if (!is_array($allowed)) {
		$allowed = [];
	}

	if (($cfg["scope"] ?? "user") === "server") {
		$users = hst_mfp_exec_json("v-list-users json");
		if (!empty($users)) {
			foreach (array_keys($users) as $u) {
				if (!is_string($u) || !preg_match('/^[a-zA-Z0-9._-]+$/', $u)) {
					continue;
				}
				$domains = hst_mfp_exec_json("v-list-mail-domains " . escapeshellarg($u) . " json");
				foreach ($domains as $dom => $meta) {
					if (is_array($meta) && (($meta["SUSPENDED"] ?? "no") === "yes")) {
						continue;
					}
					if (is_string($dom)) {
						hst_mfp_add_domain_key($allowed, $dom);
					}
				}
			}
			return $allowed;
		}

		// Fallback if Hestia CLI returned empty user list: scan Exim domains directory.
		$exim_dir = hst_mfp_exim_domains_dir();
		if (is_dir($exim_dir) && is_readable($exim_dir)) {
			$entries = @scandir($exim_dir);
			if (is_array($entries)) {
				foreach ($entries as $entry) {
					if ($entry === "." || $entry === "..") {
						continue;
					}
					if (is_dir($exim_dir . "/" . $entry)) {
						hst_mfp_add_domain_key($allowed, $entry);
					}
				}
			}
		}
		return $allowed;
	}

	$clean_user = trim($target_user, "'\"");
	if ($clean_user !== "" && preg_match('/^[a-zA-Z0-9._-]+$/', $clean_user)) {
		$domains = hst_mfp_exec_json("v-list-mail-domains " . escapeshellarg($clean_user) . " json");
		foreach ($domains as $dom => $meta) {
			if (is_array($meta) && (($meta["SUSPENDED"] ?? "no") === "yes")) {
				continue;
			}
			if (is_string($dom)) {
				hst_mfp_add_domain_key($allowed, $dom);
			}
		}
	}

	return $allowed;
}

/**
 * Inspect candidate forwarding addresses and return those blocked by the active policy.
 *
 * @param string[] $targets
 * @return string[]
 */
function hst_mfp_find_blocked_targets(
	array $targets,
	string $target_user,
	array $cfg,
	bool $allow_blackhole = true,
): array {
	$allowed = hst_mfp_get_allowed_domains($target_user, $cfg);
	$blocked = [];
	$seen = [];

	foreach ($targets as $target) {
		$item = trim((string) $target);
		if ($item === "") {
			continue;
		}
		if (strtolower($item) === ":blackhole:") {
			if ($allow_blackhole) {
				continue;
			}
			$key = ":blackhole:";
			if (!isset($seen[$key])) {
				$seen[$key] = true;
				$blocked[] = $item;
			}
			continue;
		}
		$domain = hst_mfp_extract_domain($item);
		if ($domain === "" || !isset($allowed[$domain])) {
			$key = strtolower($item);
			if (!isset($seen[$key])) {
				$seen[$key] = true;
				$blocked[] = $item;
			}
		}
	}

	return $blocked;
}

/**
 * Determine whether a HestiaCP user has the "admin" role.
 */
function hst_mfp_is_user_admin(string $username): bool {
	$clean = trim($username, "'\"");
	if ($clean === "" || !preg_match('/^[a-zA-Z0-9._-]+$/', $clean)) {
		return false;
	}
	$data = hst_mfp_exec_json("v-list-user " . escapeshellarg($clean) . " json");
	$role = $data[$clean]["ROLE"] ?? "";
	return $role === "admin";
}

/**
 * Format a clear user-facing error message without control characters or double HTML encoding.
 *
 * @param string[] $blocked
 */
function hst_mfp_format_error(array $blocked, string $scope, string $context_label): string {
	$list = implode(", ", $blocked);
	$list = preg_replace('/[\x00-\x1f\x7f]/', "", $list) ?? "";
	$has_gettext = function_exists("_");

	if ($context_label === "catchall") {
		if ($scope === "server") {
			return $has_gettext
				? sprintf(
					_(
						"External catch-all forwarding is disabled by server policy to protect server mail deliverability (%s). Only email addresses belonging to mail domains hosted on this server are permitted. To read messages in Gmail, Outlook, or a mobile app, connect the mailbox via IMAP/SMTP instead of forwarding, or ask the server administrator to configure an exception.",
					),
					$list,
				)
				: sprintf(
					"External catch-all forwarding is disabled by server policy to protect server mail deliverability (%s). Only email addresses belonging to mail domains hosted on this server are permitted. To read messages in Gmail, Outlook, or a mobile app, connect the mailbox via IMAP/SMTP instead of forwarding, or ask the server administrator to configure an exception.",
					$list,
				);
		}
		return $has_gettext
			? sprintf(
				_(
					"External catch-all forwarding is disabled by server policy to protect server mail deliverability (%s). Only email addresses belonging to your own mail domains on this account are permitted. To read messages in Gmail, Outlook, or a mobile app, connect the mailbox via IMAP/SMTP instead of forwarding, or ask the server administrator to configure an exception.",
				),
				$list,
			)
			: sprintf(
				"External catch-all forwarding is disabled by server policy to protect server mail deliverability (%s). Only email addresses belonging to your own mail domains on this account are permitted. To read messages in Gmail, Outlook, or a mobile app, connect the mailbox via IMAP/SMTP instead of forwarding, or ask the server administrator to configure an exception.",
				$list,
			);
	}

	if ($scope === "server") {
		return $has_gettext
			? sprintf(
				_(
					"External mail forwarding is disabled by server policy to protect server mail deliverability (%s). Only email addresses belonging to mail domains hosted on this server are permitted. To read messages in Gmail, Outlook, or a mobile app, connect the mailbox via IMAP/SMTP instead of forwarding, or ask the server administrator to configure an exception.",
				),
				$list,
			)
			: sprintf(
				"External mail forwarding is disabled by server policy to protect server mail deliverability (%s). Only email addresses belonging to mail domains hosted on this server are permitted. To read messages in Gmail, Outlook, or a mobile app, connect the mailbox via IMAP/SMTP instead of forwarding, or ask the server administrator to configure an exception.",
				$list,
			);
	}

	return $has_gettext
		? sprintf(
			_(
				"External mail forwarding is disabled by server policy to protect server mail deliverability (%s). Only email addresses belonging to your own mail domains on this account are permitted. To read messages in Gmail, Outlook, or a mobile app, connect the mailbox via IMAP/SMTP instead of forwarding, or ask the server administrator to configure an exception.",
			),
			$list,
		)
		: sprintf(
			"External mail forwarding is disabled by server policy to protect server mail deliverability (%s). Only email addresses belonging to your own mail domains on this account are permitted. To read messages in Gmail, Outlook, or a mobile app, connect the mailbox via IMAP/SMTP instead of forwarding, or ask the server administrator to configure an exception.",
			$list,
		);
}

/**
 * Validate new mail forwards or catch-all destinations from the HestiaCP web panel.
 * Admin sessions (including when impersonating any user via $_SESSION["look"]) bypass this restriction.
 *
 * @param string[] $new_targets
 */
function hst_mfp_validate_web_forwards(
	array $new_targets,
	string $target_user,
	string $context_label = "forward",
): ?string {
	if (($_SESSION["userContext"] ?? "") === "admin") {
		return null;
	}
	if (empty($new_targets)) {
		return null;
	}

	$cfg = hst_mfp_load_config();
	if (empty($cfg["enabled"])) {
		return null;
	}
	if ($context_label === "catchall" && empty($cfg["block_catchall"])) {
		return null;
	}

	$clean_user = trim($target_user, "'\"");
	$allow_blackhole = ($context_label !== "catchall");
	$blocked = hst_mfp_find_blocked_targets($new_targets, $clean_user, $cfg, $allow_blackhole);
	if (empty($blocked)) {
		return null;
	}

	if (!defined("HESTIA_MFP_SKIP_LOG") && function_exists("hst_add_history_log")) {
		$log_user = $clean_user !== "" ? $clean_user : "system";
		$safe_list = preg_replace('/[\x00-\x1f\x7f]/', "", implode(", ", $blocked)) ?? "";
		hst_add_history_log(
			"Blocked external mail " . $context_label . " target(s): " . $safe_list,
			"Mail",
			"Warning",
			$log_user,
		);
	}

	return hst_mfp_format_error($blocked, (string) $cfg["scope"], $context_label);
}

/**
 * Enforce mail forward policy on non-admin HestiaCP REST API requests.
 *
 * @param array<string, string> $args
 */
function hst_mfp_validate_api_command(
	string $cmd,
	array $args,
	string $key_user,
	string $root_user,
): ?string {
	if ($key_user === "" || $key_user === $root_user) {
		return null;
	}

	$context_label = "";
	$target_start_index = 0;
	if ($cmd === "v-add-mail-account-forward") {
		$context_label = "forward";
		$target_start_index = 3;
	} elseif ($cmd === "v-add-mail-domain-catchall" || $cmd === "v-change-mail-domain-catchall") {
		$context_label = "catchall";
		$target_start_index = 2;
	} else {
		return null;
	}

	$cfg = hst_mfp_load_config();
	if (empty($cfg["enabled"]) || empty($cfg["enforce_api"])) {
		return null;
	}
	if ($context_label === "catchall" && empty($cfg["block_catchall"])) {
		return null;
	}

	$clean_user = trim($key_user, "'\"");
	if ($clean_user === "" || $clean_user === "." || $clean_user === ".." || !preg_match('/^[a-zA-Z0-9._-]+$/', $clean_user)) {
		return hst_mfp_format_error(["invalid user"], (string) $cfg["scope"], $context_label);
	}

	if (hst_mfp_is_user_admin($clean_user)) {
		return null;
	}

	// web/api/index.php appends received arg1..arg13 sequentially with foreach($hst_cmd_args),
	// so skipping arg4 and passing arg5 shifts arg5 into position 3 ($4 in shell).
	// Validate by positional order across all trailing positional arguments, reject unexpected
	// extra arguments, and fail closed if the target is missing.
	$pos_args = array_values($args);
	if (count($pos_args) > $target_start_index + 1) {
		return hst_mfp_format_error(["unexpected trailing argument"], (string) $cfg["scope"], $context_label);
	}
	$candidates = array_slice($pos_args, $target_start_index);
	$non_empty = [];
	foreach ($candidates as $cand) {
		$t = trim((string) $cand);
		if ($t !== "") {
			$non_empty[] = $t;
		}
	}
	if (empty($non_empty)) {
		return hst_mfp_format_error(["missing target"], (string) $cfg["scope"], $context_label);
	}

	$allow_blackhole = ($context_label !== "catchall");
	$blocked = hst_mfp_find_blocked_targets($non_empty, $clean_user, $cfg, $allow_blackhole);
	if (empty($blocked)) {
		return null;
	}

	return hst_mfp_format_error($blocked, (string) $cfg["scope"], $context_label);
}
