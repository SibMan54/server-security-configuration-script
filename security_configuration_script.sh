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


# Проверяем, запущен ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
  error "Пожалуйста, запустите этот скрипт от имени root."
  exit 1
fi

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


# Создаем нового пользователя
read -p "$(echo -e "${YELLOW}Введите имя нового пользователя: ${NC}")" username

# Проверка, существует ли пользователь
if id "$username" &>/dev/null; then
    warning "Пользователь $username уже существует!"
    if usermod -aG sudo "$username"; then
        success "Пользователю $username успешно выданы права sudo."
    else
        error "Ошибка при назначении прав sudo пользователю $username."
        exit 1
    fi
else
    if adduser "$username"; then
        success "Пользователь $username успешно создан."
        if usermod -aG sudo "$username"; then
            success "Пользователю $username успешно выданы права sudo."
        else
            error "Ошибка при назначении прав sudo пользователю $username."
            exit 1
        fi
    else
        error "Ошибка при создании пользователя $username."
        exit 1
    fi
fi

# Копирование публичного ключа SSH
ROOT_KEY_PATH="/root/.ssh/authorized_keys"
USER_KEY_PATH="/home/$username/.ssh/authorized_keys"
USER_SSH_DIR=$(dirname "$USER_KEY_PATH")

if [[ ! -d "$USER_SSH_DIR" ]]; then
    info "Создаем папку .ssh для пользователя $username..."
    mkdir -p "$USER_SSH_DIR"
    chmod 700 "$USER_SSH_DIR"
    chown "$username:$username" "$USER_SSH_DIR"
fi

if [[ ! -f "$ROOT_KEY_PATH" ]]; then
    warning "Публичный SSH ключ не найден: $ROOT_KEY_PATH"
    read -p "$(echo -e "${YELLOW}Вставьте свой публичный SSH ключ вручную: (Ctrl + X, затем Y и Enter для сохранения): ${NC}")"
    nano "$USER_KEY_PATH"
    chmod 600 "$USER_KEY_PATH"
    chown "$username:$username" "$USER_KEY_PATH"
    success "Публичный SSH ключ успешно добавлен в: $USER_KEY_PATH"
else
    if [[ -f "$USER_KEY_PATH" ]]; then
        backup_file "$USER_KEY_PATH"
    fi
    if cp -f "$ROOT_KEY_PATH" "$USER_KEY_PATH"; then
        chmod 600 "$USER_KEY_PATH"
        chown "$username:$username" "$USER_KEY_PATH"
        success "Публичный SSH ключ успешно скопирован в: $USER_KEY_PATH"
    else
        error "Ошибка при копировании публичного SSH ключа."
        exit 1
    fi
fi


### Настройка SSH ###

# Вычисляем номер текущего порта SSH
SSH_PORT=$(grep -i "Port " /etc/ssh/sshd_config | awk '{print $2}')
info "Текущий порт SSH $SSH_PORT"

# Запрос порта у пользователя
while true; do
    read -p "$(echo -e "${YELLOW}Введите желаемый порт SSH (по умолчанию 2222): ${NC}")" NEW_PORT
    NEW_PORT=${NEW_PORT:-2222}  # Используем 2222, если пользователь не ввел ничего

    # Проверка, используется ли порт
    if ss -tuln | grep -q ":$NEW_PORT\b"; then
        warn "Порт $NEW_PORT уже используется. Пожалуйста, выберите другой порт."
    else
        success "Порт $NEW_PORT свободен."
        break
    fi
done

# Функция для добавления или изменения параметра в конфиге SSH
configure_ssh() {
    local config_file="$1"
    local param="$2"
    local value="$3"

    # Проверка: параметр существует (закомментирован или активен)
    if grep -qE "^#?$param\b" "$config_file"; then
        # Убираем комментарий и заменяем значение только у первой строки с параметром
        sed -i -E "0,/^#?$param\b/ s|^#?$param.*|$param $value|" "$config_file"
    fi
}

# Путь к файлу конфигурации SSH
SSH_CONFIG="/etc/ssh/sshd_config"

# Резервное копирование файла конфигурации SSH
backup_file "$SSH_CONFIG"

# Применение изменений в конфиге SSH
info "Настраиваем SSH-соединение..."

# Изменение порта SSH
configure_ssh "$SSH_CONFIG" "Port" "$NEW_PORT"
# Запрет авторизации для root
configure_ssh "$SSH_CONFIG" "PermitRootLogin" "no"
# Запрет авторизации по паролю
configure_ssh "$SSH_CONFIG" "PasswordAuthentication" "no"
configure_ssh "$SSH_CONFIG" "PermitEmptyPasswords" "no"
# Разрешение авторизации по публичному ключу
configure_ssh "$SSH_CONFIG" "PubkeyAuthentication" "yes"
# Установка таймаута сеанса
configure_ssh "$SSH_CONFIG" "ClientAliveInterval" "300"
configure_ssh "$SSH_CONFIG" "ClientAliveCountMax" "2"
# Ограничение попыток авторизации за одну сессию SSH
configure_ssh "$SSH_CONFIG" "MaxAuthTries" "3"
# Ограничение времени до завершения аутентификации пользователя
configure_ssh "$SSH_CONFIG" "LoginGraceTime" "20"
# Отключение перенаправления TCP-трафика
# configure_ssh "$SSH_CONFIG" "AllowTcpForwarding" "no"
# Отключение перенаправления X11, которое позволяет запускать графические приложения через SSH
# configure_ssh "$SSH_CONFIG" "X11Forwarding" "no"

info "SSH конфигурация обновлена. Перезапускаем SSH-сервис..."
if systemctl restart ssh; then
    success "Сервис SSH успешно перезапущен."
else
    error "Ошибка при перезапуске SSH-сервиса. Проверьте конфигурацию."
    exit 1
fi


# Проверка подключения
info "Попробуйте подключиться по SSH с новым пользователем $username и портом $SSH_PORT или $NEW_PORT ..."
read -p "$(echo -e "${YELLOW}Получилось ли подключиться? (y/n): ${NC}")" answer
if [[ "$answer" == "y" ]]; then
    success "SSH-соединение успешно установлено."
else
    warning "Ошибка подключения. Восстанавливаем конфигурацию SSH..."
    cp -f "$SSH_CONFIG.bak" "$SSH_CONFIG"
    systemctl restart ssh
    error "Защита SSH-соединения не настроена."
    warning "Пожалуйста, проверьте правильность данных для подключения и ключей SSH и повторите попытку."
    exit 1
fi


# Активация Firewall
ufw_status=$(ufw status | grep -i "")
if [[ "$ufw_status" == *"inactive"* ]]; then
    read -p "$(echo -e "${YELLOW}Вы хотите активировать Firewall? (y/n): ${NC}")" answer
    if [[ "$answer" == "y" ]]; then
        # Активируем Firewall
        echo "y" | ufw enable > /dev/null 2>&1
        success "Firewall активирован."
        ufw allow $NEW_PORT/tcp
        success "Порт $NEW_PORT добавлен в список разрешённых (или уже был добавлен)."
        ufw reload
        ufw status numbered
    fi
else
    success "Firewall уже активирован. Добавляем порт $NEW_PORT..."
    ufw allow $NEW_PORT/tcp
    success "Порт $PORT добавлен в список разрешённых (или уже был добавлен)."
    ufw reload
    ufw status numbered
fi

# Активация автоматических обновлений
read -p "$(echo -e "${YELLOW}Вы хотите включить автоматическое обновление? (y/n): ${NC}")" answer
if [[ "$answer" == "y" ]]; then
    if bash <(curl -Ls https://raw.githubusercontent.com/SibMan54/server-security-configuration-script/refs/heads/main/auto_updates_enable.sh); then
        success "Автоматические обновления успешно включены."
    else
        error "Ошибка при активации автоматических обновлений."
    fi
fi

# Установка и настройка Fail2ban
read -p "$(echo -e "${YELLOW}Вы хотите настроить Fail2ban для защиты от брутфорса SSH? (y/n): ${NC}")" answer
if [[ "$answer" == "y" ]]; then
    if bash <(curl -Ls "https://raw.githubusercontent.com/SibMan54/server-security-configuration-script/refs/heads/main/fail2ban_setup.sh"); then
        success "Fail2ban успешно установлен и настроен"
    else
        error "Ошибка: Fail2ban не был установлен. Проверьте логи или выполните настройку вручную."
    fi
fi

# Установка 3X-UI
if ! command -v x-ui &> /dev/null; then
    read -p "$(echo -e "${YELLOW}Вы хотите установить 3X-UI панель? (y/n): ${NC}")" answer
    if [[ "$answer" == "y" ]]; then
        if bash <(curl -Ls https://raw.githubusercontent.com/SibMan54/install-3x-ui-add-signed-ssl-cert/refs/heads/main/install_3x-ui_add_ssl_cert.sh); then
            success "3X-UI успешно установлен."
        else
            error "Ошибка установки 3X-UI."
            exit 1
        fi
    else
        warning "Установка 3X-UI отменена пользователем."
    fi
else
    success "3X-UI уже установлен."
fi


echo ""
echo "==========================================================="
echo -e "1. ${BLUE}Создан новый пользователь $username.${NC}"
echo -e "2. ${BLUE}Публичный SSH ключ успешно добавлен в: $USER_KEY_PATH.${NC}"
echo -e "3. ${BLUE}Конфигурация SSH успешно изменена, порт изменен на $NEW_PORT. Используйте его при следующем подключении к серверу.${NC}"
counter=3
ufw_status=$(sudo ufw status | grep -o "Status: active")
if [ "$ufw_status" == "Status: active" ]; then
    counter=$((counter + 1))
    echo -e "$counter. ${BLUE}Firewall активирован, порт $NEW_PORT добавляем в разрешенные.${NC}"
fi
if systemctl is-active --quiet unattended-upgrades; then
    if grep -m 1 '^Unattended-Upgrade::Automatic-Reboot "true";' /etc/apt/apt.conf.d/50unattended-upgrades | grep -qv "^[[:space:]]*//"; then
        counter=$((counter + 1))
        echo -e "$counter. ${BLUE}Автоматическая проверка и установка обновлений безопасности включена и настроена.${NC}"
    else
        counter=$((counter + 1))
        echo -e "$counter. ${YELLOW}Автоматическая проверка и установка обновлений включена, но изменения для безопастности обновлений не были внесены.${NC}"
    fi
fi
if command -v fail2ban-client &>/dev/null; then
    if grep -Pzo "\[sshd\]\n\s*enabled\s*=\s*true" /etc/fail2ban/jail.local &>/dev/null; then
        counter=$((counter + 1))
        echo -e "$counter. ${BLUE}Fail2ban установлен и настроен для защиты от брутфорса SSH.${NC}"
    else
        counter=$((counter + 1))
        echo -e "$counter. ${YELLOW}Fail2ban установлен, НО не настроен для защиты от брутфорса SSH.${NC}"
    fi
fi
if command -v x-ui &> /dev/null; then
    counter=$((counter + 1))
    echo -e "$counter. ${BLUE}Панель 3X-UI установлена.${NC}"
fi
echo -e "${GREEN}✅ Настройка завершена, сервер теперь в безопастности!${NC}"
echo -e "${YELLOW}⚠️ Чтобы изменения вступили в силу, необходимо:${NC}"
echo -e "${CYAN}- Перезагрузить SSH-сервис командой ->${NC} systemctl restart ssh"
echo -e "${CYAN}- Или полностью перезагрузить сервер командой ->${NC} reboot"
echo "==========================================================="
