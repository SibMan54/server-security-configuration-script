#!/bin/bash

# --- Функция для вывода сообщений ---
function success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1"
}
function error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
}
function warning() {
    echo -e "\e[33m[WARNING]\e[0m $1"
}
function info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

# --- Функция для создания резервной копии файла ---
backup_file() {
    local file="$1"
    local backup="$1.bak"

    if [ ! -f "$backup" ]; then
        info "Создаю резервную копию файла $file..."
        cp "$file" "$backup"
    else
        success "Резервная копия файла $file уже существует."
    fi
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
info "Настраиваем Fail2ban..."
FAIL2BAN_CONFIG="/etc/fail2ban/jail.local"
backup_file "$FAIL2BAN_CONFIG"

cat <<EOF > "$FAIL2BAN_CONFIG"
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $NEW_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
EOF

if [[ $? -eq 0 ]]; then
    success "Конфигурация Fail2ban успешно создана."
else
    error "Ошибка при создании конфигурации Fail2ban."
    exit 1
fi

# --- Перезапуск Fail2ban ---
info "Перезапускаем Fail2ban для применения изменений..."
if systemctl restart fail2ban; then
    success "Fail2ban успешно перезапущен."
else
    error "Не удалось перезапустить Fail2ban."
    exit 1
fi

# --- Проверка статуса Fail2ban ---
info "Проверяем статус Fail2ban..."
if systemctl status fail2ban > /dev/null 2>&1; then
    success "Fail2ban работает корректно."
else
    error "Fail2ban не запущен. Проверьте логи для диагностики."
    exit 1
fi
