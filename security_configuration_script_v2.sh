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
trap 'on_error $LINENO' ERR

on_interrupt() {
    printf '\n'
    warning "Получен сигнал прерывания. Выход без дальнейших изменений."
    log_action "Interrupted by user"
    exit 130
}
trap on_interrupt INT TERM

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
    local unit sshd_output ports root_login password_auth pubkey_auth
    if ! unit=$(service_name_ssh); then
        audit_add FAIL "SSH server" "OpenSSH server service unit not found"
        return
    fi
    if systemctl is-active --quiet "$unit"; then audit_add OK "SSH service" "Active ($unit)"; else audit_add WARN "SSH service" "Inactive ($unit)"; fi
    if systemctl is-enabled --quiet "$unit"; then audit_add OK "SSH boot startup" "Enabled"; else audit_add WARN "SSH boot startup" "Not enabled"; fi
    if ! command -v sshd >/dev/null 2>&1; then audit_add WARN "SSH configuration" "sshd binary unavailable"; return; fi
    if ! sshd_output=$(sshd -T 2>/dev/null); then audit_add FAIL "SSH configuration" "sshd -T failed; configuration needs investigation"; return; fi
    audit_add OK "SSH syntax/effective config" "sshd -T completed successfully"
    ports=$(awk '$1=="port" {print $2}' <<< "$sshd_output" | paste -sd, -)
    audit_add INFO "Effective SSH port(s)" "${ports:-not reported}"
    root_login=$(awk '$1=="permitrootlogin" {print $2}' <<< "$sshd_output" | tail -n1)
    password_auth=$(awk '$1=="passwordauthentication" {print $2}' <<< "$sshd_output" | tail -n1)
    pubkey_auth=$(awk '$1=="pubkeyauthentication" {print $2}' <<< "$sshd_output" | tail -n1)
    [[ "$root_login" == no ]] && audit_add OK "Root SSH login" "Disabled" || audit_add WARN "Root SSH login" "${root_login:-unknown}"
    [[ "$password_auth" == no ]] && audit_add OK "SSH password auth" "Disabled" || audit_add WARN "SSH password auth" "${password_auth:-unknown}"
    [[ "$pubkey_auth" == yes ]] && audit_add OK "SSH public-key auth" "Enabled" || audit_add WARN "SSH public-key auth" "${pubkey_auth:-unknown}"
    if command -v ss >/dev/null 2>&1; then
        local listening
        listening=$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | paste -sd, -)
        audit_add INFO "TCP listen sockets" "${listening:-none detected}"
    fi
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
            2) module_placeholder 'SSH' ;;
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

check_root
check_os
initialize
main_menu
