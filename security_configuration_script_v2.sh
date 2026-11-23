#!/usr/bin/env bash
# Server Security Configuration Script
# Version: 2.0.0-dev.1
# Development branch: dev-2.0
# Initial scaffold: menu, environment checks, logging, read-only audit.

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0-dev.1"
SCRIPT_TITLE="Server Security Configuration Script"
LOG_DIR="/var/log/server-security-script"
LOG_FILE="${LOG_DIR}/security-script.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'

info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warning() { printf "${YELLOW}[WARNING]${NC} %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
separator(){ printf "${GRAY}%s${NC}\n" "------------------------------------------------------------"; }

log_action() {
    [[ -d "$LOG_DIR" ]] || return 0
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

on_error() {
    local code=$? line=${1:-?}
    trap - ERR
    error "Команда завершилась с ошибкой (код ${code}, строка ${line})."
    log_action "ERROR code=${code} line=${line}"
    return "$code"
}
on_interrupt() {
    printf '\\n'
    warning "Получен сигнал прерывания. Выход без дальнейших изменений."
    log_action "Interrupted by user"
    exit 130
}

pause_menu() {
    printf '\n'
    read -r -p 'Нажмите Enter для возврата в меню...' _ || true
}

confirm() {
    local prompt=${1:-Продолжить?}
    local answer
    read -r -p "$prompt [y/N]: " answer || return 1
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

check_root() {
    if (( EUID != 0 )); then
        error "Запустите скрипт от root (например: sudo bash script.sh)."
        exit 1
    fi
}

check_os() {
    [[ -r /etc/os-release ]] || { error "Файл /etc/os-release недоступен."; exit 1; }
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_NAME=${NAME:-Linux}
    OS_VERSION=${VERSION_ID:-unknown}
    OS_ID=${ID:-unknown}
    if [[ "$OS_ID" != ubuntu ]]; then
        warning "Скрипт ориентирован на Ubuntu. Обнаружено: ${OS_NAME} ${OS_VERSION}."
        confirm "Продолжить на неподтверждённой ОС?" || exit 0
    fi
}

initialize() {
    install -d -m 700 "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    log_action "Started v${SCRIPT_VERSION}"
}

show_header() {
    clear || true
    printf "\n${CYAN}╔══════════════════════════════════════════════════════════╗\n"
    printf "║       SERVER SECURITY CONFIGURATION SCRIPT             ║\n"
    printf "║                    VERSION 2.0                      ║\n"
    printf "╚══════════════════════════════════════════════════════════╝${NC}\n\n"
    printf "\033[1;37mOS:${NC} %s %s\n" "$OS_NAME" "$OS_VERSION"
    printf "Version: %s\n\n" "$SCRIPT_VERSION"
    separator
}

# Audit result counters: audit is read-only; no remediation occurs here.
# Audit framework: structured results, strictly read-only.
AUDIT_OK=0; AUDIT_WARN=0; AUDIT_FAIL=0; AUDIT_INFO=0
AUDIT_ROWS=()

audit_reset() {
    AUDIT_OK=0; AUDIT_WARN=0; AUDIT_FAIL=0; AUDIT_INFO=0
    AUDIT_ROWS=()
}
audit_add() {
    local level="$1" label="$2" details="$3"
    case "$level" in
        OK) ((AUDIT_OK+=1)) ;;
        WARN) ((AUDIT_WARN+=1)) ;;
        FAIL) ((AUDIT_FAIL+=1)) ;;
        INFO) ((AUDIT_INFO+=1)) ;;
        *) level="INFO"; ((AUDIT_INFO+=1)) ;;
    esac
    AUDIT_ROWS+=("$level|$label|$details")
}
status_ok()   { audit_add OK "$1" "$2"; }
status_warn()  { audit_add WARN "$1" "$2"; }
status_fail()  { audit_add FAIL "$1" "$2"; }
status_info()  { audit_add INFO "$1" "$2"; }
audit_print() {
    local row level label details
    printf "\\n%-7s %-30s %s\\n" "STATUS" "CHECK" "DETAILS"
    separator
    for row in "${AUDIT_ROWS[@]}"; do
        IFS='|' read -r level label details <<< "$row"
        case "$level" in
            OK) printf "${GREEN}%-7s${NC} %-30s %s\\n" "$level" "$label" "$details" ;;
            WARN) printf "${YELLOW}%-7s${NC} %-30s %s\\n" "$level" "$label" "$details" ;;
            FAIL) printf "${RED}%-7s${NC} %-30s %s\\n" "$level" "$label" "$details" ;;
            *) printf "${BLUE}%-7s${NC} %-30s %s\\n" "$level" "$label" "$details" ;;
        esac
    done
    separator
    printf "Summary: ${GREEN}%d OK${NC} | ${YELLOW}%d warnings${NC} | ${RED}%d errors${NC} | %d info\\n" "$AUDIT_OK" "$AUDIT_WARN" "$AUDIT_FAIL" "$AUDIT_INFO"
}

service_name_ssh() {
    if systemctl cat ssh.service >/dev/null 2>&1; then printf 'ssh'; return 0; fi
    if systemctl cat sshd.service >/dev/null 2>&1; then printf 'sshd'; return 0; fi
    return 1
}

audit_ssh() {
    local unit sshd_output ports root_login password_auth pubkey_auth listen_info
    if ! unit=$(service_name_ssh); then
        audit_add FAIL "SSH server" "OpenSSH server service unit not found"
        return
    fi
    if systemctl is-active --quiet "$unit"; then audit_add OK "SSH service" "Active ($unit)"; else audit_add WARN "SSH service" "Inactive ($unit)"; fi
    if systemctl is-enabled --quiet "$unit"; then audit_add OK "SSH boot startup" "Enabled"; else audit_add WARN "SSH boot startup" "Not enabled"; fi
    if ! command -v sshd >/dev/null 2>&1; then audit_add WARN "SSH configuration" "sshd binary unavailable"; return; fi
    if ! sshd_output=$(sshd -T 2>/dev/null); then audit_add FAIL "SSH configuration" "sshd -T failed; configuration needs investigation"; return; fi
    audit_add OK "SSH config validation" "sshd -T completed successfully"
    ports=$(awk '$1=="port" {print $2}' <<< "$sshd_output" | sort -nu | paste -sd " " -)
    audit_add INFO "Configured SSH port(s)" "${ports:-not reported}"
    root_login=$(awk '$1=="permitrootlogin" {print $2}' <<< "$sshd_output" | tail -n1)
    password_auth=$(awk '$1=="passwordauthentication" {print $2}' <<< "$sshd_output" | tail -n1)
    pubkey_auth=$(awk '$1=="pubkeyauthentication" {print $2}' <<< "$sshd_output" | tail -n1)
    [[ "$root_login" == no ]] && audit_add OK "Root SSH login" "Disabled" || audit_add WARN "Root SSH login" "${root_login:-unknown}"
    [[ "$password_auth" == no ]] && audit_add OK "SSH password auth" "Disabled" || audit_add WARN "SSH password auth" "${password_auth:-unknown}"
    [[ "$pubkey_auth" == yes ]] && audit_add OK "SSH public-key auth" "Enabled" || audit_add WARN "SSH public-key auth" "${pubkey_auth:-unknown}"
    if command -v ss >/dev/null 2>&1; then
        listen_info=$(ss -ltnH 2>/dev/null | awk '{print $4}' | paste -sd, -)
        audit_add INFO "TCP listening endpoints" "${listen_info:-No TCP listeners detected}"
        local p
        for p in $ports; do
            if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"; then
                audit_add OK "Port ${p} listener" "TCP socket found"
            else
                audit_add WARN "Port ${p} listener" "No matching TCP listener detected (socket activation or service state may affect this)"
            fi
        done
    else
        audit_add INFO "TCP listeners" "ss command not available"
    fi
    audit_ssh_keys
}

audit_ssh_keys() {
    local sshd_output key_paths path expanded user uid home file_count=0 key_count=0
    if ! command -v sshd >/dev/null 2>&1 || ! sshd_output=$(sshd -T 2>/dev/null); then
        audit_add INFO "Authorized keys" "Skipped; effective SSH config unavailable"
        return
    fi
    key_paths=$(awk '$1=="authorizedkeysfile" {$1=""; sub(/^ /,""); print}' <<< "$sshd_output" | tail -n1)
    [[ -z "$key_paths" ]] && key_paths=".ssh/authorized_keys"
    # Enumerate accounts including root (UID 0). AuthorizedKeysFile paths are expanded
    # according to sshd's common %h/%u/%U tokens. Key content is never displayed.
    while IFS=: read -r user _ uid _ _ home _; do
        [[ -n "$home" && "$home" != "/" && -d "$home" ]] || continue
        for path in $key_paths; do
            expanded="$path"
            expanded=${expanded//%h/$home}
            expanded=${expanded//%u/$user}
            expanded=${expanded//%U/$uid}
            [[ "$expanded" == /* ]] || expanded="$home/$expanded"
            [[ -f "$expanded" ]] || continue
            if [[ -s "$expanded" ]]; then
                local count
                count=$(grep -Ec '(^|[[:space:]])(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-ssh-|sk-ecdsa-)' "$expanded" 2>/dev/null || true)
                audit_add INFO "Authorized keys: $user" "$expanded ($count key-like line(s); contents not shown)"
                ((file_count+=1))
                ((key_count+=count))
            else
                audit_add WARN "Authorized keys: $user" "$expanded exists but is empty"
            fi
        done
    done < <(getent passwd)
    if (( file_count > 0 )); then
        audit_add OK "Authorized keys files" "Found $file_count file(s); approximately $key_count key entries detected (root included)"
    else
        audit_add WARN "Authorized keys files" "No populated authorized_keys files detected (root included)"
    fi
}

audit_ssh_host_keys() {
    local hostkey keyfile pubfile fingerprint found=0
    if [[ ! -d /etc/ssh ]]; then audit_add WARN "SSH host keys" "/etc/ssh directory missing"; return; fi
    shopt -s nullglob
    for keyfile in /etc/ssh/ssh_host_*_key; do
        [[ "$keyfile" == *.pub ]] && continue
        pubfile="${keyfile}.pub"
        if [[ -f "$keyfile" && -f "$pubfile" ]]; then
            if fingerprint=$(ssh-keygen -lf "$pubfile" 2>/dev/null); then
                audit_add OK "Host key: ${keyfile##*/}" "$(awk '{print $2}' <<< "$fingerprint")"
                ((found+=1))
            else
                audit_add WARN "Host key: ${keyfile##*/}" "Public key exists but fingerprint could not be read"
            fi
            if [[ "$(stat -c '%a' "$keyfile" 2>/dev/null)" =~ ^[0-7]+$ ]] && (( 10#$(stat -c '%a' "$keyfile") > 600 )); then
                audit_add WARN "Host key permissions" "${keyfile##*/}: mode should be restrictive (actual $(stat -c '%a' "$keyfile"))"
            fi
        elif [[ -f "$keyfile" ]]; then
            audit_add WARN "Host key: ${keyfile##*/}" "Private key present; matching public key file missing"
        fi
    done
    shopt -u nullglob
    ((found>0)) && audit_add OK "SSH host keys" "${found} public fingerprints readable" || audit_add WARN "SSH host keys" "No usable host key pairs found"
}

ssh_audit_screen() {
    show_header
    printf "${CYAN}SSH SECURITY AUDIT (READ-ONLY)${NC}\\n\\n"
    audit_reset
    audit_ssh
    audit_ssh_host_keys
    audit_print
    log_action "SSH-only audit complete: ok=$AUDIT_OK warn=$AUDIT_WARN fail=$AUDIT_FAIL info=$AUDIT_INFO"
    pause_menu
}

ssh_show_effective_config() {
    show_header
    printf "${CYAN}EFFECTIVE SSH CONFIGURATION${NC}\\n\\n"
    if ! command -v sshd >/dev/null 2>&1; then
        warning "sshd command not found."
    elif ! sshd -T 2>/dev/null; then
        error "Could not read effective sshd configuration. Review the config before proceeding."
    else
        local effective
        effective=$(sshd -T 2>/dev/null) || effective=""
        if [[ -n "$effective" ]]; then
            printf "%s\\n" "$effective" | grep -E '^(port |permitrootlogin |passwordauthentication |pubkeyauthentication |maxauthtries |logingracetime |allowtcpforwarding |x11forwarding |clientaliveinterval |clientalivecountmax )' || true
        fi
    fi
    pause_menu
}

ssh_keys_audit_screen() {
    show_header
    printf "${CYAN}SSH AUTHORIZED KEYS (READ-ONLY)${NC}\\n\\n"
    audit_reset
    audit_ssh_keys
    audit_print
    pause_menu
}

ssh_hostkeys_screen() {
    show_header
    printf "${CYAN}SSH SERVER HOST KEYS (READ-ONLY)${NC}\\n\\n"
    audit_reset
    audit_ssh_host_keys
    audit_print
    pause_menu
}

SSH_BACKUP_DIR="/var/backups/server-security-script/ssh"

ssh_preflight_screen() {
    show_header
    printf "${CYAN}SSH CONFIGURATION PREFLIGHT (READ-ONLY) ${NC}\\n\\n"
    local sshd_bin unit port_output socket_state ufw_state config_main
    config_main="/etc/ssh/sshd_config"
    sshd_bin=$(command -v sshd || true)
    if [[ -z "$sshd_bin" ]]; then
        status_warn "OpenSSH server binary" "sshd is not installed or not in PATH"
    else
        status_ok "OpenSSH server binary" "$sshd_bin"
        if sshd -t 2>/dev/null; then status_ok "SSH config syntax" "sshd -t passed"; else status_fail "SSH config syntax" "sshd -t failed; do not modify config until fixed"; fi
    fi
    if unit=$(service_name_ssh); then
        if systemctl is-active --quiet "$unit"; then status_ok "SSH service" "$unit is active"; else status_warn "SSH service" "$unit is not active"; fi
    else
        status_warn "SSH service unit" "Could not find ssh/sshd unit"
    fi
    if command -v sshd >/dev/null 2>&1 && port_output=$(sshd -T 2>/dev/null); then
        port_output=$(awk '$1=="port" {print $2}' <<< "$port_output" | sort -nu | paste -sd, -)
        status_info "Effective SSH ports" "${port_output:-not determined}"
    fi
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        status_info "Socket activation" "ssh.socket is active; socket unit may control listening port"
    elif systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        status_info "Socket activation" "ssh.socket is enabled"
    else
        status_info "Socket activation" "No active/enabled ssh.socket detected"
    fi
    if command -v ss >/dev/null 2>&1; then
        local listeners
        listeners=$(ss -ltnH 2>/dev/null | awk '{print $4}' | paste -sd, -)
        status_info "Listening TCP endpoints" "${listeners:-none found}"
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw_state=$(ufw status 2>/dev/null | head -n1 || true)
        status_info "UFW status" "${ufw_state:-unknown}"
    else
        status_info "UFW status" "UFW not installed"
    fi
    if [[ -f "$config_main" ]]; then
        status_ok "Main config" "$config_main"
        local includes
        includes=$(grep -nE '^[[:space:]]*Include[[:space:]]+' "$config_main" 2>/dev/null || true)
        [[ -n "$includes" ]] && status_info "Include directives" "$includes" || status_info "Include directives" "No Include lines in main file"
    else
        status_fail "Main config" "$config_main not found"
    fi
    printf "\\n"
    pause_menu
}

ssh_backup_configs() {
    show_header
    printf "${CYAN}SSH CONFIGURATION BACKUP${NC}\\n\\n"
    local timestamp archive
    if [[ ! -f /etc/ssh/sshd_config ]]; then
        error "Main SSH configuration file not found; backup cancelled."
        pause_menu
        return
    fi
    if ! command -v tar >/dev/null 2>&1; then
        error "tar is required to create a backup."
        pause_menu
        return
    fi
    install -d -m 700 "$SSH_BACKUP_DIR" || { error "Cannot create backup directory"; pause_menu; return; }
    timestamp=$(date '+%Y%m%d-%H%M%S')
    archive="$SSH_BACKUP_DIR/ssh-config-${timestamp}.tar.gz"
    # Archive the main config and the optional drop-in directory, without SSH host keys.
    local -a archive_paths=(sshd_config)
    [[ -d /etc/ssh/sshd_config.d ]] && archive_paths+=(sshd_config.d)
    if tar -czf "$archive" -C /etc/ssh "${archive_paths[@]}"; then
        chmod 600 "$archive"
        success "SSH configuration backup created: $archive"
        log_action "SSH config backup: $archive"
    else
        rm -f "$archive"
        error "Backup failed; incomplete archive removed."
    fi
    pause_menu
}

# SSH config editor safety helpers. Designed to accept alternate paths for isolated tests.
ssh_config_editor_supported() {
    local config="${1:-/etc/ssh/sshd_config}" dropin_dir="${2:-/etc/ssh/sshd_config.d}"
    [[ -f "$config" ]] || return 1
    # Keep initial editor conservative: only simple, global directives are accepted.
    if grep -Eiq '^[[:space:]]*(Include|Match)[[:space:]]+' "$config"; then return 1; fi
    if [[ -d "$dropin_dir" ]] && compgen -G "$dropin_dir/*.conf" >/dev/null; then return 1; fi
    return 0
}

# Rewrite exactly one active directive in a supplied file, or append it if absent.
# This helper is intentionally path-parameterized so it can be unit-tested in temp dirs.
# Callers must backup the real file and validate the resulting sshd config before reload.
ssh_config_rewrite_directive() {
    local config="$1" key="$2" value="$3" temp count
    [[ -f "$config" && ! -L "$config" ]] || return 1
    [[ "$key" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9-]+$ ]] || return 1
    count=$(grep -Eic "^[[:space:]]*${key}[[:space:]]+" "$config" || true)
    (( count <= 1 )) || return 2
    temp=$(mktemp "${config}.tmp.XXXXXX") || return 1
    if ! awk -v key="$key" -v val="$value" '
        BEGIN { found_directive=0 }
        /^[[:space:]]*#/ { print; next }
        {
            if (tolower($1) == tolower(key) && !found_directive) { print key " " val; found_directive=1; next }
            print
        }
        END { if (!found_directive) print key " " val }
    ' "$config" > "$temp" 2>"$temp.awk.err"; then
        rm -f "$temp.awk.err"
        chown --reference="$config" "$temp" 2>/dev/null || true
        chmod --reference="$config" "$temp" 2>/dev/null || chmod 600 "$temp"
        mv -f "$temp" "$config"
        return 0
    fi
    if [[ -s "$temp.awk.err" ]]; then
        cat "$temp.awk.err" >&2
    fi
    rm -f "$temp" "$temp.awk.err"
    return 1
}

# Transaction wrapper for SSH directive edits. A caller-supplied validator (function or command)
# must validate the candidate configuration. On validation failure, restore the exact prior file.
ssh_config_editor_transaction() {
    local config="$1" key="$2" value="$3" validator="$4"
    local backup restore_tmp
    [[ -f "$config" && ! -L "$config" ]] || return 1
    [[ -n "$validator" ]] || return 1
    command -v "$validator" >/dev/null 2>&1 || declare -F "$validator" >/dev/null 2>&1 || return 1

    backup=$(mktemp "${config}.backup.XXXXXX") || return 1
    if ! cp -a -- "$config" "$backup"; then
        rm -f -- "$backup"
        return 1
    fi

    if ! ssh_config_rewrite_directive "$config" "$key" "$value"; then
        rm -f -- "$backup"
        return 1
    fi

    if "$validator" "$config"; then
        rm -f -- "$backup"
        return 0
    fi

    restore_tmp=$(mktemp "${config}.restore.XXXXXX") || {
        cp -a -- "$backup" "$config"
        rm -f -- "$backup"
        return 1
    }
    if cp -a -- "$backup" "$restore_tmp" && mv -f -- "$restore_tmp" "$config"; then
        rm -f -- "$backup"
        return 1
    fi
    rm -f -- "$restore_tmp"
    # Last-resort restoration attempt if atomic restoration failed.
    cp -a -- "$backup" "$config" || true
    rm -f -- "$backup"
    return 1
}

ssh_editor_safe_mode() {
    show_header
    printf "${CYAN}SSH EDITOR PREFLIGHT (READ-ONLY)${NC}\\n\\n"
    local config="/etc/ssh/sshd_config"
    if [[ ! -f "$config" ]]; then error "Missing $config"; pause_menu; return; fi
    if ! sshd -t 2>/dev/null; then
        error "Current SSH configuration is invalid; fix it before editing."
        pause_menu; return
    fi
    if ! ssh_config_editor_supported "$config" "/etc/ssh/sshd_config.d"; then
        warning "Include/Match/drop-in configuration detected. Editor refuses this layout."
    elif systemctl is-active --quiet ssh.socket 2>/dev/null; then
        warning "Socket activation is active. Editor refuses to proceed."
    else
        success "Config appears eligible for a limited editor (still not enabled for writes)."
    fi
    info "No changes made."
    pause_menu
}

ssh_hardening_profile_preview() {
    show_header
    printf "${CYAN}SSH HARDENING PROFILE — PREVIEW ONLY${NC}\\n\\n"
    local config="/etc/ssh/sshd_config" effective root_value pass_value pub_value tries grace choice
    if [[ ! -f "$config" ]] || ! command -v sshd >/dev/null 2>&1; then
        error "sshd_config or sshd is missing."
        pause_menu; return
    fi
    if ! sshd -t 2>/dev/null; then
        error "Current config is invalid. No changes will be made."
        pause_menu; return
    fi
    if grep -Eq '^[[:space:]]*(Include|Match)[[:space:]]+' "$config" || { [[ -d /etc/ssh/sshd_config.d ]] && compgen -G '/etc/ssh/sshd_config.d/*.conf' >/dev/null; }; then
        warning "Complex Include/Match/drop-in config detected. Preview only; editor will not write."
    fi
    effective=$(sshd -T 2>/dev/null) || { error "Unable to obtain effective SSH config."; pause_menu; return; }
    root_value=$(awk '$1=="permitrootlogin"{print $2}' <<< "$effective" | tail -n1)
    pass_value=$(awk '$1=="passwordauthentication"{print $2}' <<< "$effective" | tail -n1)
    pub_value=$(awk '$1=="pubkeyauthentication"{print $2}' <<< "$effective" | tail -n1)
    tries=$(awk '$1=="maxauthtries"{print $2}' <<< "$effective" | tail -n1)
    grace=$(awk '$1=="logingracetime"{print $2}' <<< "$effective" | tail -n1)
    printf "Current effective settings:\\n PermitRootLogin: %s\\n PasswordAuthentication: %s\\n PubkeyAuthentication: %s\\n MaxAuthTries: %s\\n LoginGraceTime: %s\\n\\n" "$root_value" "$pass_value" "$pub_value" "$tries" "$grace"
    printf "Choose a preview profile (nothing will be written):\\n"
    printf "1. Recommended: RootLogin no, PasswordAuthentication no, PubkeyAuthentication yes, MaxAuthTries 3, LoginGraceTime 30\\n"
    printf "2. Conservative: RootLogin prohibit-password, PasswordAuthentication yes, PubkeyAuthentication yes, MaxAuthTries 3, LoginGraceTime 30\\n"
    printf "0. Cancel\\n"
    read -r -p "Choice: " choice || { pause_menu; return; }
    case "$choice" in
        1) root_value=no; pass_value=no; pub_value=yes; tries=3; grace=30 ;;
        2) root_value=prohibit-password; pass_value=yes; pub_value=yes; tries=3; grace=30 ;;
        0) return ;;
        *) warning "Invalid choice."; pause_menu; return ;;
    esac
    printf "\\nProposed values (preview):\\n PermitRootLogin %s\\n PasswordAuthentication %s\\n PubkeyAuthentication %s\\n MaxAuthTries %s\\n LoginGraceTime %s\\n\\n" "$root_value" "$pass_value" "$pub_value" "$tries" "$grace"
    warning "Preview only: no file edits, service reload, or firewall changes were made."
    log_action "SSH hardening profile preview selected: $choice (no modifications)"
    pause_menu
}


ssh_configuration_menu() {
    local choice
    while true; do
        show_header
        printf "${CYAN}SSH MANAGEMENT${NC}\n\n"
        printf "1. Full SSH security audit (read-only)\n"
        printf "2. Show effective SSH settings\n"
        printf "3. Inspect user authorized_keys (root included)\n"
        printf "4. Inspect server Host Keys\n"
        printf "5. Editor preflight (read-only)\n"
        printf "6. Apply interactive SSH hardening\n"
        printf "7. Create SSH configuration backup\n\n"
        separator
        printf "0. Back\n\n"
        read -r -p 'Select an option: ' choice || return
        case "$choice" in
            1) ssh_audit_screen ;;
            2) ssh_show_effective_config ;;
            3) ssh_keys_audit_screen ;;
            4) ssh_hostkeys_screen ;;
            5) ssh_editor_safe_mode ;;
            6) ssh_hardening_profile_preview ;;
            7) ssh_backup_configs ;;
            0) return ;;
            *) warning "Invalid selection."; sleep 1 ;;
        esac
    done
}

audit_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then audit_add WARN "UFW firewall" "Not installed"; return; fi
    local status
    status=$(ufw status 2>/dev/null | head -n1)
    if [[ "$status" == "Status: active" ]]; then
        audit_add OK "UFW firewall" "Active"
        local rules
        rules=$(ufw status 2>/dev/null | sed -n '2,8p' | paste -sd '; ' -)
        audit_add INFO "Firewall rules (sample)" "${rules:-No rules shown}"
    else
        audit_add WARN "UFW firewall" "${status:-Status unavailable}"
    fi
}

audit_fail2ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then audit_add WARN "Fail2Ban" "Not installed"; return; fi
    if ! systemctl is-active --quiet fail2ban; then audit_add WARN "Fail2Ban service" "Installed but inactive"; return; fi
    audit_add OK "Fail2Ban service" "Active"
    local jails
    if jails=$(fail2ban-client status 2>/dev/null); then
        jails=$(sed -n 's/.*Jail list:[[:space:]]*//p' <<< "$jails" | tr -d ' ')
        [[ -n "$jails" ]] && audit_add OK "Fail2Ban jails" "$jails" || audit_add WARN "Fail2Ban jails" "No jails listed"
    else
        audit_add WARN "Fail2Ban status" "Could not read jail status"
    fi
}

audit_swap() {
    local total
    total=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)
    if (( ${total:-0} > 0 )) && swapon --show --noheadings 2>/dev/null | grep -q .; then
        audit_add OK "Swap" "Active; total configured: ${total} KiB"
    else
        audit_add WARN "Swap" "No active swap detected"
    fi
}

audit_updates() {
    if command -v apt-get >/dev/null 2>&1; then
        if [[ -f /var/lib/apt/lists/lock ]]; then audit_add INFO "Package updates" "APT metadata present; update check not run (read-only audit)" 
        else audit_add INFO "Package updates" "APT detected; audit does not refresh package lists"; fi
    else
        audit_add INFO "Package updates" "APT not detected; skipped"
    fi
    if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
        audit_add OK "Automatic security updates" "unattended-upgrades installed"
    else
        audit_add WARN "Automatic security updates" "unattended-upgrades not installed"
    fi
}

audit_sysctl() {
    local key value
    for key in net.ipv4.ip_forward net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects net.ipv4.conf.all.rp_filter; do
        if value=$(sysctl -n "$key" 2>/dev/null); then
            audit_add INFO "Sysctl: $key" "$value (value reported; suitability depends on use)"
        else
            audit_add WARN "Sysctl: $key" "Unable to read"
        fi
    done
}

audit_basic() {
    show_header
    printf "${CYAN}READ-ONLY SYSTEM AUDIT${NC}\\n\\n"
    audit_reset
    audit_add INFO "OS" "${OS_NAME} ${OS_VERSION} (${OS_ID})"
    audit_ssh
    audit_ssh_host_keys
    audit_firewall
    audit_fail2ban
    audit_swap
    audit_updates
    audit_sysctl
    audit_print
    log_action "Audit completed: ok=$AUDIT_OK warn=$AUDIT_WARN fail=$AUDIT_FAIL info=$AUDIT_INFO"
    pause_menu
}

# Feature modules are placeholders until individually designed and implemented.
# Selecting one currently makes no system changes.
module_placeholder() {
    local module_name=$1
    show_header
    info "Module '${module_name}' is not implemented yet. No changes were made."
    log_action "Placeholder selected: ${module_name}"
    pause_menu
}

main_menu() {
    local choice
    while true; do
        show_header
        printf "\033[1;37mSERVER CONFIGURATION${NC}\n\n"
        printf " 1. System updates\n"
        printf " 2. SSH configuration\n"
        printf " 3. UFW Firewall\n"
        printf " 4. Fail2Ban\n"
        printf " 5. Sysctl hardening\n"
        printf " 6. Swap\n"
        printf " 7. Utilities\n"
        printf " 8. Security auto-updates\n"
        printf " 9. Additional security settings\n\n"
        separator
        printf "10. System audit (read-only)\n"
        printf "11. Apply all recommended settings\n"
        printf "12. Configuration backups\n"
        printf "13. Restore configuration\n\n"
        printf " 0. Exit\n\n"
        read -r -p 'Select an option: ' choice || exit 0
        case "$choice" in
            1) module_placeholder 'System updates' ;;
            2) ssh_configuration_menu ;;
            3) module_placeholder 'UFW Firewall' ;;
            4) module_placeholder 'Fail2Ban' ;;
            5) module_placeholder 'Sysctl' ;;
            6) module_placeholder 'Swap' ;;
            7) module_placeholder 'Utilities' ;;
            8) module_placeholder 'Security auto-updates' ;;
            9) module_placeholder 'Additional security' ;;
            10) audit_basic ;;
            11) module_placeholder 'Apply all' ;;
            12) module_placeholder 'Backup' ;;
            13) module_placeholder 'Restore' ;;
            0) log_action 'Exited'; printf '\n'; success 'Exiting.'; exit 0 ;;
            *) warning 'Invalid selection.'; sleep 1 ;;
        esac
    done
}

# Source-safe guard: tests can load functions without starting the interactive program.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'on_error $LINENO' ERR
    trap on_interrupt INT TERM
    check_root
    check_os
    initialize
    main_menu
fi
