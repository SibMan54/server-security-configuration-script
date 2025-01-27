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

# --- Проверяем наличие пакета unattended-upgrades ---
if ! which unattended-upgrades > /dev/null 2>&1; then
    info "Установка unattended-upgrades..."
    apt update && apt install unattended-upgrades -y
else
    success "unattended-upgrades уже установлен."
fi

# --- Настройка unattended-upgrades ---
info "Конфигурация unattended-upgrades..."
dpkg-reconfigure --priority=low unattended-upgrades

# --- Редактируем конфигурационный файл ---
CONF_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"
backup_file "$CONF_FILE"
info "Редактируем файл конфигурации $CONF_FILE..."
sed -i 's|^\s*"\${distro_id}:\${distro_codename}";|//      "${distro_id}:${distro_codename}";|g' "$CONF_FILE"
sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|g' "$CONF_FILE"

# --- Проверяем файл 20auto-upgrades ---
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
backup_file "$AUTO_UPGRADES_FILE"
info "Включаем ежедневные обновления в $AUTO_UPGRADES_FILE..."
if ! grep -q "APT::Periodic::Update-Package-Lists" "$AUTO_UPGRADES_FILE"; then
    echo 'APT::Periodic::Update-Package-Lists "1";' >> "$AUTO_UPGRADES_FILE"
else
    sed -i 's/^APT::Periodic::Update-Package-Lists.*/APT::Periodic::Update-Package-Lists "1";/' "$AUTO_UPGRADES_FILE"
fi

if ! grep -q "APT::Periodic::Unattended-Upgrade" "$AUTO_UPGRADES_FILE"; then
    echo 'APT::Periodic::Unattended-Upgrade "1";' >> "$AUTO_UPGRADES_FILE"
else
    sed -i 's/^APT::Periodic::Unattended-Upgrade.*/APT::Periodic::Unattended-Upgrade "1";/' "$AUTO_UPGRADES_FILE"
fi

# --- Запуск и включение службы unattended-upgrades ---
systemctl start unattended-upgrades
systemctl enable unattended-upgrades

# --- Проверка статуса службы ---
if systemctl is-active --quiet unattended-upgrades; then
    success "Служба unattended-upgrades запущена."
else
    warning "Служба unattended-upgrades не запущена."
fi
