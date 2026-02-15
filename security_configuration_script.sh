#!/bin/bash

##### TAG #####

# Определение цветов
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
NC='\033[0m' # Сброс цвета

# --- Функции для вывода сообщений ---
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

# -------------------------------
# Создаем нового пользователя
# -------------------------------
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

# -------------------------------
# Копирование публичного ключа SSH
# -------------------------------
SSH_KEY="/root/.ssh/authorized_keys"
USER_SSH_KEY="/home/$username/.ssh/authorized_keys"
USER_KEY_PATH=$(dirname "$USER_SSH_KEY")

# Проверяем существует ли папка .ssh в папке пользователя
if [[ ! -d "$USER_KEY_PATH" ]]; then
    info "Создаем папку .ssh для пользователя $username..."
    mkdir -p "$USER_KEY_PATH"
    chmod 700 "$USER_KEY_PATH"
    chown "$username:$username" "$USER_KEY_PATH"
fi

# Проверяем, существует ли SSH ключ в папке пользователя
if [[ -f "$USER_SSH_KEY" && -s "$USER_SSH_KEY" && $(grep -q '^ssh' "$USER_SSH_KEY" && echo "found") ]]; then
    success "SSH ключ уже существует в: $USER_SSH_KEY"
    # Создаем бэкап файла ключа
    backup_file "$USER_SSH_KEY"
else
    # Проверяем, существует ли SSH ключ в папке root пользователя
    if [[ -f "$SSH_KEY" && -s "$SSH_KEY" && $(grep -q '^ssh' "$SSH_KEY" && echo "found") ]]; then
        # Файл authorized_keys существует и он не пустой, копируем его
        if cp -f "$SSH_KEY" "$USER_SSH_KEY"; then
            chmod 600 "$USER_SSH_KEY"
            chown "$username:$username" "$USER_SSH_KEY"
            success "Публичный SSH ключ успешно скопирован в: $USER_SSH_KEY"
        else
            error "Ошибка при копировании публичного SSH ключа."
            exit 1
        fi
    else
        # Файл authorized_keys не найден или пуст
        warning "Публичный SSH ключ не найден в: $SSH_KEY"
        read -p "$(echo -e "${YELLOW}Введите ваш публичный SSH-ключ: ${NC}")" PUB_KEY
        if [[ -n "$PUB_KEY" ]]; then
            # Создаем или заполняем файл authorized_keys
            echo "$PUB_KEY" > "$USER_SSH_KEY"
            chmod 600 "$USER_SSH_KEY"
            chown "$username:$username" "$USER_SSH_KEY"
            success "Ключ успешно добавлен в: $USER_SSH_KEY"
        else
            error "Ключ не был введен. Завершение."
            exit 1
        fi
    fi
fi

# -------------------------------
# Настройка защиты SSH
# -------------------------------

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
# Ограничение количества попыток входа
configure_ssh "$SSH_CONFIG" "MaxAuthTries" "3"
# Время ожидания перед завершением сессии (в секундах)
configure_ssh "$SSH_CONFIG" "LoginGraceTime" "30"
# Отключите, если не используете проброс портов
configure_ssh "$SSH_CONFIG" "AllowTcpForwarding" "no"
# Отключите, если не нужен X11, которое позволяет запускать графические приложения через SSH
configure_ssh "$SSH_CONFIG" "X11Forwarding" "no"
# Установите интервал проверки активности клиента
configure_ssh "$SSH_CONFIG" "ClientAliveInterval" "300"
# Количество проверок активности перед завершением сессии
configure_ssh "$SSH_CONFIG" "ClientAliveCountMax" "2"

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

# -------------------------------
# Активация Firewall
# -------------------------------
ufw_status=$(ufw status | grep -i "")
if [[ "$ufw_status" == *"inactive"* ]]; then
    read -p "$(echo -e "${YELLOW}Вы хотите активировать Firewall? (y/n): ${NC}")" answer
    if [[ "$answer" == "y" ]]; then
        # Активируем Firewall
        ufw --force enable
        success "Firewall активирован."
        ufw allow $NEW_PORT/tcp
        success "Порт $NEW_PORT добавлен в список разрешённых (или уже был добавлен)."
        ufw reload
        ufw status numbered
    else
        info "Активация Firewall пропущена пользователем."
    fi
else
    success "Firewall уже активирован. Добавляем порт $NEW_PORT..."
    ufw allow $NEW_PORT/tcp
    success "Порт $PORT добавлен в список разрешённых (или уже был добавлен)."
    ufw reload
    ufw status numbered
fi

# -------------------------------
# Отключение ping (ICMP echo-request) по запросу пользователя
# -------------------------------
BEFORE_RULES="/etc/ufw/before.rules"
if grep -q "^-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT" "$BEFORE_RULES"; then
    read -p "$(echo -e "${YELLOW}Отключить пингование сервера (ICMP echo-request)? (y/n): ${NC}")" icmp_answer
    if [[ "$icmp_answer" == "y" ]]; then

        backup_file "$BEFORE_RULES"

        sed -i 's|^-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT|# -A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT|' "$BEFORE_RULES"

        ufw reload
        success " Пингование сервера отключено (ICMP echo-request закомментировано)."
    else
        info "Отключение ping пропущено пользователем."
    fi
else
    success "Ping уже отключён или правило уже закомментировано."
fi

# -------------------------------
# Активация автоматических обновлений
# -------------------------------
if systemctl is-active --quiet unattended-upgrades; then
    if grep -m 1 '^Unattended-Upgrade::Automatic-Reboot "true";' /etc/apt/apt.conf.d/50unattended-upgrades | grep -qv "^[[:space:]]*//"; then
        success "Автообновления уже активированы"
    else
        read -p "$(echo -e "${YELLOW}Вы хотите включить автоматическое обновление? (y/n): ${NC}")" answer
        if [[ "$answer" == "y" ]]; then
            if bash <(curl -Ls https://raw.githubusercontent.com/SibMan54/server-security-configuration-script/refs/heads/main/auto_updates_enable.sh); then
                success "Автоматические обновления успешно активированы."
            else
                error "Ошибка при активации автоматических обновлений."
            fi
        else
            info "Активация автоматических обновлений пропущена пользователем."
        fi
    fi
fi

# -------------------------------
# Установка и настройка Fail2ban
# -------------------------------
if command -v fail2ban-client &>/dev/null; then
    if grep -Pzo "\[sshd\]\n\s*enabled\s*=\s*true" /etc/fail2ban/jail.local &>/dev/null; then
        success "Fail2ban уже установлен"
    else
        read -p "$(echo -e "${YELLOW}Вы хотите настроить Fail2ban для защиты от брутфорса SSH? (y/n): ${NC}")" answer
        if [[ "$answer" == "y" ]]; then
            if bash <(curl -Ls "https://raw.githubusercontent.com/SibMan54/server-security-configuration-script/refs/heads/main/fail2ban_setup.sh"); then
                success "Fail2ban успешно установлен и настроен."
            else
                error "Ошибка: Fail2ban не был установлен. Проверьте логи или выполните настройку вручную."
            fi
        else
            info "Установка и настройка Fail2ban пропущена пользователем."
        fi
    fi
fi

# -------------------------------
# Установка 3X-UI
# -------------------------------

# Функция установки 3X-UI через оф. скрипт
install_3xui_official() {
    info "Установка 3X-UI через официальный скрипт..."

    # Проверяем статус UFW
    if ufw status | grep -q "Status: active"; then
        FIREWALL_ACTIVE=true
        info "Отключаем Firewall (ufw)..."
        ufw disable
    else
        FIREWALL_ACTIVE=false
        info "Firewall уже отключён."
    fi

    # Установка 3X-UI
    if bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh); then
        success "3X-UI успешно установлен."
    else
        error "Ошибка установки 3X-UI."
        [[ "$FIREWALL_ACTIVE" == true ]] && ufw --force enable
        exit 1
    fi

    # Включаем Firewall обратно
    if [[ "$FIREWALL_ACTIVE" == true ]]; then
        local PANEL_PORT
        read -p "Введите порт панели вручную: " PANEL_PORT
        if [[ -n "$PANEL_PORT" ]]; then
            info "Добавляем порт $PANEL_PORT в firewall..."
            ufw allow "$PANEL_PORT/tcp"
        else
            warning "Введен неверный порт, добавьте порт в firewall вручную."
        fi
        info "Добавляем порт 433 в firewall..."
        ufw allow 443/tcp
        info "Включаем Firewall обратно..."
        ufw --force enable
    fi
}

# Функция установки 3X-UI-PRO
install_3xui_pro() {
    info "Выбрана установка 3x-UI-PRO."

    if bash <(wget -qO- https://github.com/mozaroc/x-ui-pro/raw/master/x-ui-pro.sh) -install yes -panel 1 -ONLY_CF_IP_ALLOW no; then
        success "3x-UI-PRO успешно установлен."
    else
        error "Ошибка при установке 3x-UI-PRO."
        return 1
    fi
}

# Функция коректировки cron-задания acme.sh
fix_acme_cron() {
    info "Исправляем cron-задачу acme.sh (временное открытие порта 80)..."

    local OPEN="ufw allow 80/tcp"
    local CLOSE="ufw deny 80/tcp"

    crontab -l 2>/dev/null | while IFS= read -r line; do

        # не acme — просто печатаем
        if ! echo "$line" | grep -q 'acme.sh --cron'; then
            echo "$line"
            continue
        fi

        # уже обёрнуто — НЕ трогаем
        if echo "$line" | grep -q 'ufw allow 80/tcp.*acme.sh --cron.*ufw deny 80/tcp'; then
            echo "$line"
            continue
        fi

        # === здесь ТОЛЬКО чистая оригинальная строка ===
        schedule=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
        command=$(echo "$line" | cut -d' ' -f6-)

        echo "$schedule $OPEN && $command && $CLOSE"

    done | crontab -

    success "CRON-задание acme.sh обработано корректно."
}

# Если 3X-UI не установлен, выбираем вариант установки
if ! command -v x-ui &> /dev/null; then
    read -p "$(echo -e "${YELLOW}Вы хотите установить 3X-UI панель? (y/n): ${NC}")" answer

    if [[ "$answer" == "y" ]]; then
        echo -e "${YELLOW}Выберите вариант установки 3X-UI:${NC}"
        echo "1) Официальный скрипт"
        echo "2) Версия 3X-UI-PRO (добавлены настроенные инбаунды и подписки, установлен Nginx с сайтом заглушкой)"
        read -p "Введите 1 или 2: " UI_CHOICE

        case "$UI_CHOICE" in
            1)
                install_3xui_official
                fix_acme_cron
                ;;
            2)
                install_3xui_pro
                ;;
            *)
                error "Неверный выбор. Установка 3X-UI отменена."
                exit 1
                ;;
        esac
    else
        info "Установка 3X-UI пропущена пользователем."
    fi
else
    success "3X-UI уже установлен."
fi

# -------------------------------
# Установка SpeedTest
# -------------------------------
if command -v speedtest > /dev/null 2>&1; then
    success "Speedtest CLI уже установлен."
else
    read -p "$(echo -e "${YELLOW}Установить SpeedTest ? (y/n): ${NC}")" answer
    if [[ "$answer" == "y" ]]; then
        # Установка Speedtest CLI
        if bash <(curl -Ls https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh) && apt install -y speedtest-cli; then
            rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list
            success "Speedtest CLI успешно установлен."
        else
            error "Ошибка установки Speedtest CLI."
            exit 1
        fi
    else
        warning "Speedtest CLI НЕ установлен."
    fi
fi


# -------------------------------
# Финальное сообщение
# -------------------------------
echo ""
echo "==========================================================="
echo -e "1. ${BLUE}Создан новый пользователь $username.${NC}"
echo -e "2. ${BLUE}Публичный SSH ключ успешно добавлен в: $USER_SSH_KEY.${NC}"
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
