#!/bin/bash

# Проверяем, запущен ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт от имени root."
  exit 1
fi

# Функция для создания резервной копии файла
backup_file() {
    local file="$1"
    local backup="$1.bak"

    if [ ! -f "$backup" ]; then
        echo "Создаю резервную копию файла $file..."
        cp "$file" "$backup"
    else
        echo "Резервная копия файла $file уже существует."
    fi
}

# Создаем нового пользователя
read -p "Введите имя нового пользователя: " username

# Проверка, существует ли пользователь
if id "$username" &>/dev/null; then
  echo "Пользователь $username уже существует!"
  # Выдаем новому пользователю права sudo
  if usermod -aG sudo "$username"; then
    echo "Пользователю $username успешно выданы права sudo."
  else
    echo "Ошибка при назначении прав sudo пользователю $username."
    exit 1
  fi
else
  # Создаем нового пользователя
  if adduser "$username"; then
    echo "Пользователь $username успешно создан."
    # Выдаем новому пользователю права sudo
    if usermod -aG sudo "$username"; then
      echo "Пользователю $username успешно выданы права sudo."
    else
      echo "Ошибка при назначении прав sudo пользователю $username."
      exit 1
    fi
  else
    echo "Ошибка при создании пользователя $username."
    exit 1
  fi
fi


# Копирование публичного ключа SSH в папку пользователя
# Путь к вашему публичному SSH-ключу
ROOT_KEY_PATH="/root/.ssh/authorized_keys"

# Путь к файлу ключа в папке пользователя
USER_KEY_PATH="/home/$username/.ssh/authorized_keys"

# Создаем папку .ssh, если она не существует
USER_SSH_DIR=$(dirname "$USER_KEY_PATH")
if [[ ! -d "$USER_SSH_DIR" ]]; then
    echo "Создаем папку .ssh для пользователя $username..."
    mkdir -p "$USER_SSH_DIR"
    chmod 700 "$USER_SSH_DIR"
    chown "$username:$username" "$USER_SSH_DIR"
fi

# Проверяем, существует ли публичный ключ
if [[ ! -f "$ROOT_KEY_PATH" ]]; then
    echo "Публичный SSH ключ не найден: $ROOT_KEY_PATH"
    echo "Вставьте свой публичный SSH ключ вручную:"
    echo "После ввода нажмите Ctrl + X, затем Y и Enter для сохранения."
    read -p "Нажмите Enter для редактирования файла authorized_keys..."
    nano "$USER_KEY_PATH"
    chmod 600 "$USER_KEY_PATH"
    chown "$username:$username" "$USER_KEY_PATH"
    echo "Публичный SSH ключ успешно добавлен в: $USER_KEY_PATH"
else
    if [[ -f "$USER_KEY_PATH" ]]; then
    # Создаем резервную копию существующего файла ключа, если он есть
    backup_file "$USER_KEY_PATH"
    fi

    # Копируем публичный ключ в папку назначения
    if cp -f "$ROOT_KEY_PATH" "$USER_KEY_PATH"; then
        chmod 600 "$USER_KEY_PATH"
        chown "$username:$username" "$USER_KEY_PATH"
        echo "Публичный SSH ключ успешно скопирован в: $USER_KEY_PATH"
    else
        echo "Ошибка при копировании публичного SSH ключа."
        exit 1
    fi
fi

# Конфигурация SSH

# Вычисляем номер текущего порта SSH
SSH_PORT=$(grep -i "Port " /etc/ssh/sshd_config | awk '{print $2}')

# Запрос порта у пользователя
echo ""
while true; do
    read -p "Введите желаемый порт SSH (по умолчанию 2222): " NEW_PORT
    NEW_PORT=${NEW_PORT:-2222}  # Используем 2222, если пользователь не ввел ничего

    # Проверка, используется ли порт
    if ss -tuln | grep -q ":$NEW_PORT\b"; then
        echo "Порт $NEW_PORT уже используется. Пожалуйста, выберите другой порт."
    else
        echo "Порт $NEW_PORT свободен."
        break
    fi
done

# Путь к файлу конфигурации SSH
SSH_CONFIG="/etc/ssh/sshd_config"

# Резервное копирование файла конфигурации SSH
backup_file "$SSH_CONFIG"

# Изменение порта SSH
sed -i "s/^#Port 22/Port $NEW_PORT/" $SSH_CONFIG
sed -i "s/^Port 22/Port $NEW_PORT/" $SSH_CONFIG

# Запрет авторизации для root
sed -i "s/^#PermitRootLogin yes/PermitRootLogin no/" $SSH_CONFIG
sed -i "s/^PermitRootLogin yes/PermitRootLogin no/" $SSH_CONFIG

# Запрет авторизации по паролю
sed -i "s/^#PasswordAuthentication yes/PasswordAuthentication no/" $SSH_CONFIG
sed -i "s/^PasswordAuthentication yes/PasswordAuthentication no/" $SSH_CONFIG
sed -i "s/^#PermitEmptyPasswords no/PermitEmptyPasswords no/" $SSH_CONFIG

# Разрешение авторизации по публичному ключу
sed -i "s/^#PubkeyAuthentication yes/PubkeyAuthentication yes/" $SSH_CONFIG

# Перезапуск SSH-сервиса для применения изменений
echo "Перезапускаем SSH-сервис..."
systemctl restart ssh

# Проверка подключения после изменений
echo ""
echo "Попробуйте подключиться по SSH с новым пользователем $username и портом $SSH_PORT или $NEW_PORT..."
read -p "Получилось ли подключиться? (y/n): " answer
if [[ "$answer" == "y" ]]; then
    echo "SSH-соединение успешно установлено. Защита SSH-соединения настроена."
else
    # Восстанавливаем конфиг SSH
    cp -f "$SSH_CONFIG".bak "$SSH_CONFIG"
    echo "Ошибка при подключении по SSH. Защита SSH-соединения не настроена."
    echo "Пожалуйста, проверьте правильность данных для подключения и ключей SSH и повторите попытку."
    exit 1
fi


# Активация Firewall
# Проверяем статус UFW
ufw_status=$(ufw status | grep -i "")
if [[ "$ufw_status" == *"inactive"* ]]; then
    echo ""
    read -p "Вы хотите активировать Firewall ? (y/n): " answer
    if [[ "$answer" == "y" ]]; then
        ufw enable
        ufw allow $NEW_PORT/tcp
        ufw reload
        ufw status numbered
    fi
else
    echo "Firewall уже включен, добавляем порт $NEW_PORT в список разрешенных"
    ufw allow $NEW_PORT/tcp
    ufw reload
    ufw status numbered
fi


# Активация автоматических обновлений
echo ""
read -p "Вы хотите включить автоматическое обновление ? (y/n): " answer
if [[ "$answer" == "y" ]]; then
    # включаем автообновления
    bash <(curl -Ls https://raw.githubusercontent.com/SibMan54/server-security-configuration-script/refs/heads/main/auto_updates_enable.sh)
fi


# Установка 3X-UI
echo ""
read -p "Вы хотите установить 3X-UI панель ? (y/n): " answer
if [[ "$answer" == "y" ]]; then
    if ! command -v x-ui &> /dev/null; then
        bash <(curl -Ls https://raw.githubusercontent.com/SibMan54/install-3x-ui-add-signed-ssl-cert/refs/heads/main/install_3x-ui_add_ssl_cert.sh)
        if [ $? -ne 0 ]; then
            exit 1
        fi
    else
        echo "3X-UI уже установлен."
    fi
fi


echo ""
echo "==========================================================="
echo "1. Создан новый пользователь $username"
echo "2. Публичный SSH ключ успешно добавлен в: $USER_KEY_PATH"
echo "3. Конфигурация SSH успешно изменена, порт изменен на $NEW_PORT. Используйте его при следующем подключении к серверу."
counter=3
ufw_status=$(sudo ufw status | grep -o "Status: active")
if [ "$ufw_status" == "Status: active" ]; then
    counter=$((counter + 1))
    echo "$counter. Firewall активирован, порт $NEW_PORT добавляем в разрешенные."
fi
CONF_BAK_FILE="/etc/apt/apt.conf.d/50unattended-upgrades.bak"
if systemctl is-active --quiet unattended-upgrades; then
    if [[ -f "$CONF_BAK_FILE" ]]; then
        counter=$((counter + 1))
        echo "$counter. Автоматическая проверка и установка обновлений безопасности включена и настроена."
    else
    counter=$((counter + 1))
    echo "$counter. Автоматическая проверка и установка обновлений включена, но изменения для безопастности обновлений не были внесены."
    fi
fi
if command -v x-ui &> /dev/null; then
    counter=$((counter + 1))
    echo "$counter. Панель 3X-UI установлена."
fi
echo ">> Настройка завершена, сервер теперь в безопастности!"
echo ">> Чтобы изменения вступили в силу, нужно перезагрузить сервер командой «reboot»."
echo "==========================================================="
