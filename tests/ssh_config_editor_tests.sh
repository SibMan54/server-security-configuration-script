#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../security_configuration_script_v2.sh"
source "$SCRIPT"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
assert_true() {
 local name="$1"; shift
 if "$@"; then printf 'PASS: %s\n' "$name"; ((pass+=1)); else printf 'FAIL: %s\n' "$name"; ((fail+=1)); fi
}
assert_false() {
 local name="$1"; shift
 if "$@"; then printf 'FAIL: %s\n' "$name"; ((fail+=1)); else printf 'PASS: %s\n' "$name"; ((pass+=1)); fi
}
assert_contains() {
 local name="$1" expected="$2" file="$3"
 if grep -Fq -- "$expected" "$file"; then printf 'PASS: %s\n' "$name"; ((pass+=1)); else printf 'FAIL: %s\n' "$name"; ((fail+=1)); fi
}
assert_not_contains() {
 local name="$1" expected="$2" file="$3"
 if grep -Fq -- "$expected" "$file"; then printf 'FAIL: %s\n' "$name"; ((fail+=1)); else printf 'PASS: %s\n' "$name"; ((pass+=1)); fi
}

cfg="$TEST_ROOT/sshd_config"
printf 'Port 22\nPasswordAuthentication yes\n' > "$cfg"
assert_true "rewrite existing directive succeeds" ssh_config_rewrite_directive "$cfg" PasswordAuthentication no
assert_contains "existing directive updated" "PasswordAuthentication no" "$cfg"
assert_not_contains "old active value removed" "PasswordAuthentication yes" "$cfg"
assert_true "append missing directive succeeds" ssh_config_rewrite_directive "$cfg" PermitRootLogin no
assert_contains "missing directive appended" "PermitRootLogin no" "$cfg"

cfg_comment="$TEST_ROOT/commented.conf"
printf '# PasswordAuthentication yes\nPort 22\n' > "$cfg_comment"
assert_true "commented directive rewrite succeeds" ssh_config_rewrite_directive "$cfg_comment" PasswordAuthentication no
assert_contains "comment remains" "# PasswordAuthentication yes" "$cfg_comment"
assert_contains "active value appended" "PasswordAuthentication no" "$cfg_comment"

cfg_dupe="$TEST_ROOT/duplicate.conf"
printf 'PasswordAuthentication yes\nPasswordAuthentication no\n' > "$cfg_dupe"
before=$(sha256sum "$cfg_dupe")
assert_false "duplicate directives refused" ssh_config_rewrite_directive "$cfg_dupe" PasswordAuthentication no
after=$(sha256sum "$cfg_dupe")
if [[ "$before" == "$after" ]]; then printf 'PASS: duplicate file remains unchanged\n'; ((pass+=1)); else printf 'FAIL: duplicate file remains unchanged\n'; ((fail+=1)); fi

assert_false "reject invalid directive name" ssh_config_rewrite_directive "$cfg" 'Bad Key' no
assert_false "reject unsafe value" ssh_config_rewrite_directive "$cfg" PasswordAuthentication 'no; touch /tmp/x'

# SSH directives are case-insensitive: test mixed case and duplicate rejection.
cfg_case="$TEST_ROOT/case-mixed.conf"
printf 'passwordauthentication yes\n' > "$cfg_case"
assert_true "mixed-case directive rewrite succeeds" ssh_config_rewrite_directive "$cfg_case" PasswordAuthentication no
assert_contains "mixed-case directive replaced" "PasswordAuthentication no" "$cfg_case"
assert_not_contains "mixed-case old value absent" "passwordauthentication yes" "$cfg_case"

cfg_case_dupe="$TEST_ROOT/case-duplicate.conf"
printf 'PasswordAuthentication yes\npasswordauthentication no\n' > "$cfg_case_dupe"
before_case=$(sha256sum "$cfg_case_dupe")
assert_false "case-insensitive duplicates rejected" ssh_config_rewrite_directive "$cfg_case_dupe" PasswordAuthentication no
after_case=$(sha256sum "$cfg_case_dupe")
if [[ "$before_case" == "$after_case" ]]; then printf 'PASS: mixed-case duplicate file remains unchanged\n'; ((pass+=1)); else printf 'FAIL: mixed-case duplicate file remains unchanged\n'; ((fail+=1)); fi

cfg_mode="$TEST_ROOT/mode.conf"
printf 'Port 22\n' > "$cfg_mode"
chmod 640 "$cfg_mode"
assert_true "rewrite with permissions" ssh_config_rewrite_directive "$cfg_mode" Port 2222
mode=$(stat -c '%a' "$cfg_mode")
if [[ "$mode" == 640 ]]; then printf 'PASS: permissions preserved (640)\n'; ((pass+=1)); else printf 'FAIL: permissions preserved (got %s)\n' "$mode"; ((fail+=1)); fi

simple="$TEST_ROOT/simple.conf"
dropins="$TEST_ROOT/empty-dropins"
mkdir -p "$dropins"
printf 'Port 22\n' > "$simple"
assert_true "simple configuration eligible" ssh_config_editor_supported "$simple" "$dropins"

inc="$TEST_ROOT/include.conf"
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' > "$inc"
assert_false "Include directive rejected" ssh_config_editor_supported "$inc" "$dropins"
match="$TEST_ROOT/match.conf"
printf 'Port 22\nMatch User test\n PasswordAuthentication yes\n' > "$match"
assert_false "Match block rejected" ssh_config_editor_supported "$match" "$dropins"

# Directive names are case-insensitive, so lowercase Include/Match are also refused.
inc_lower="$TEST_ROOT/include-lowercase.conf"
printf 'include /etc/ssh/sshd_config.d/*.conf\\n' > "$inc_lower"
assert_false "lowercase Include rejected" ssh_config_editor_supported "$inc_lower" "$dropins"
match_lower="$TEST_ROOT/match-lowercase.conf"
printf 'match user test\\n passwordauthentication yes\\n' > "$match_lower"
assert_false "lowercase Match rejected" ssh_config_editor_supported "$match_lower" "$dropins"

printf 'PasswordAuthentication no\n' > "$dropins/10-hardening.conf"
assert_false "drop-in directory rejected" ssh_config_editor_supported "$simple" "$dropins"
assert_false "missing config rejected" ssh_config_editor_supported "$TEST_ROOT/missing.conf" "$dropins"


# Transaction tests: accepted edits persist; rejected edits restore original bytes and metadata.
validator_accept() { [[ -f "$1" ]] && grep -q 'PasswordAuthentication no' "$1"; }
validator_reject() { return 1; }

cfg_tx_ok="$TEST_ROOT/transaction-success.conf"
printf 'PasswordAuthentication yes\\nPort 22\\n' > "$cfg_tx_ok"
chmod 640 "$cfg_tx_ok"
assert_true "transaction accepted by validator" ssh_config_editor_transaction "$cfg_tx_ok" PasswordAuthentication no validator_accept
assert_contains "transactional edit persisted" "PasswordAuthentication no" "$cfg_tx_ok"
mode_tx=$(stat -c '%a' "$cfg_tx_ok")
if [[ "$mode_tx" == 640 ]]; then printf 'PASS: transaction preserves mode (640)\\n'; ((pass+=1)); else printf 'FAIL: transaction preserves mode (got %s)\\n' "$mode_tx"; ((fail+=1)); fi

cfg_tx_fail="$TEST_ROOT/transaction-rollback.conf"
printf 'PasswordAuthentication yes\\nPort 22\\n' > "$cfg_tx_fail"
chmod 640 "$cfg_tx_fail"
before_tx=$(sha256sum "$cfg_tx_fail")
assert_false "transaction rejected by validator" ssh_config_editor_transaction "$cfg_tx_fail" PasswordAuthentication no validator_reject
after_tx=$(sha256sum "$cfg_tx_fail")
if [[ "$before_tx" == "$after_tx" ]]; then printf 'PASS: rollback restores exact file contents\\n'; ((pass+=1)); else printf 'FAIL: rollback restores exact file contents\\n'; ((fail+=1)); fi
mode_after_tx=$(stat -c '%a' "$cfg_tx_fail")
if [[ "$mode_after_tx" == 640 ]]; then printf 'PASS: rollback restores file mode (640)\\n'; ((pass+=1)); else printf 'FAIL: rollback restores file mode (got %s)\\n' "$mode_after_tx"; ((fail+=1)); fi


# Symlink safety: editor must refuse to follow links to another file.
cfg_link_target="$TEST_ROOT/link-target.conf"
cfg_link="$TEST_ROOT/link.conf"
printf 'PasswordAuthentication yes\\n' > "$cfg_link_target"
ln -s "$cfg_link_target" "$cfg_link"
assert_false "rewrite refuses symlink target" ssh_config_rewrite_directive "$cfg_link" PasswordAuthentication no
assert_false "transaction refuses symlink target" ssh_config_editor_transaction "$cfg_link" PasswordAuthentication no validator_accept
assert_contains "symlink target content unchanged" "PasswordAuthentication yes" "$cfg_link_target"

printf '\nTest results: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
