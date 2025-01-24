#!/bin/bash

##### TAG #####

# Определение цветов
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
NC='\033[0m' # Сброс цвета

# Функции для цветного вывода
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}
warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}
error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

##### END TAG #####
#
# Функция для создания резервной копии файла
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

# Проверяем наличие пакета unattended-upgrades
if ! which unattended-upgrades > /dev/null 2>&1; then
    info "Установка unattended-upgrades..."
    apt update && apt install unattended-upgrades -y
else
    success "unattended-upgrades уже установлен."
fi

# Настройка unattended-upgrades
info "Конфигурация unattended-upgrades..."
dpkg-reconfigure --priority=low unattended-upgrades

# Редактируем конфигурационный файл
CONF_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"
backup_file "$CONF_FILE"
info "Редактируем файл конфигурации $CONF_FILE..."
sed -i 's|^\s*"\${distro_id}:\${distro_codename}";|//      "${distro_id}:${distro_codename}";|g' "$CONF_FILE"
sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|g' "$CONF_FILE"

# Проверяем файл 20auto-upgrades
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

# Запуск и включение службы unattended-upgrades
systemctl start unattended-upgrades
systemctl enable unattended-upgrades

# Проверка статуса службы
if systemctl is-active --quiet unattended-upgrades; then
    success "Служба unattended-upgrades запущена."
else
    warning "Служба unattended-upgrades не запущена."
fi
