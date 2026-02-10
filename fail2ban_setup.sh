#!/bin/bash

##### TAG #####

# Определение цветов
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
NC="\e[0m"

# --- Функции для вывода сообщений ---
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

##### END TAG #####


# Функция для создания резервной копии файла с меткой времени
backup_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        error "Файл $file не найден, резервная копия не создана."
        return 1
    fi

    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local backup="${file}.bak.${timestamp}"

    cp "$file" "$backup"
    success "Создана резервная копия: $backup"
}

# --- Установка Fail2ban ---
# Проверка, установлен ли Fail2ban
if ! command -v fail2ban-client &>/dev/null; then
    info "Устанавливаем Fail2ban..."
    if apt-get install -y fail2ban; then
        success "Fail2ban успешно установлен."
    else
        error "Ошибка при установке Fail2ban."
        exit 1
    fi
else
    info "Fail2ban уже установлен."
fi

# --- Настройка Fail2ban ---
FAIL2BAN_CONFIG="/etc/fail2ban/jail.local"

SSH_PORT=$(grep -m1 "^Port " /etc/ssh/sshd_config | awk '{print $2}')
ENABLE_EMAIL="false"
FAIL2BAN_EMAIL=""

read -p "$(echo -e "${YELLOW}Включить email-уведомления Fail2ban? (y/n): ${NC}")" email_answer
if [[ "$email_answer" == "y" ]]; then

    # Удаляем Postfix, если установлен
    if dpkg-query -W -f='${Status}' postfix 2>/dev/null | grep -q "install ok installed"; then
        info "Удаляем Postfix..."
        DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y postfix
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
        success "Postfix удалён."
    else
        info "Postfix не установлен, пропускаем удаление."
    fi

    # Устанавливаем Sendmail, если не установлен
    if ! dpkg-query -W -f='${Status}' sendmail 2>/dev/null | grep -q "install ok installed"; then
        info "Устанавливаем Sendmail и mailutils..."
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y sendmail mailutils
        success "Sendmail установлен."
    else
        info "Sendmail уже установлен, установка не требуется."
    fi

    # Включаем и перезапускаем sendmail daemon
    info "Запускаем и включаем Sendmail..."
    systemctl enable sendmail >/dev/null 2>&1
    systemctl restart sendmail

    # 🔎 Проверяем, что Sendmail слушает порт 25
    if ss -lntp | grep -q ':25'; then
        success "Sendmail запущен и слушает порт 25."
    else
        error "Sendmail не запущен или не слушает порт 25. Email-уведомления работать не будут."
        exit 1
    fi

    # Запрашиваем email
    read -p "Введите email для уведомлений: " FAIL2BAN_EMAIL
    if [[ -n "$FAIL2BAN_EMAIL" ]]; then
        ENABLE_EMAIL="true"
        info "Email уведомления включены для: $FAIL2BAN_EMAIL"
    else
        warning "Email не указан, уведомления отключены."
        ENABLE_EMAIL="false"
    fi
fi

backup_file "$FAIL2BAN_CONFIG"

# --- Генерация jail.local ---
cat <<EOF > "$FAIL2BAN_CONFIG"
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8
EOF

if [[ "$ENABLE_EMAIL" == "true" ]]; then
cat <<EOF >> "$FAIL2BAN_CONFIG"
destemail = $FAIL2BAN_EMAIL
sender = fail2ban@$(hostname)
mta = sendmail
action = %(action_mwl)s
EOF
else
cat <<EOF >> "$FAIL2BAN_CONFIG"
action = %(action_)s
EOF
fi

cat <<EOF >> "$FAIL2BAN_CONFIG"

[sshd]
enabled = true
port = 22,2222,$SSH_PORT
logpath = /var/log/auth.log
maxretry = 3
bantime = 24h
EOF

success "Конфигурация Fail2ban создана."

# --- Перезапуск Fail2ban ---
info "Перезапускаем Fail2ban..."
systemctl restart fail2ban
success "Fail2ban перезапущен."

# --- Статус Fail2ban ---
info "Проверяем статус Fail2ban..."
if systemctl is-active --quiet fail2ban; then
    success "Fail2ban работает корректно."
else
    error "Fail2ban не запущен. Проверьте логи."
fi