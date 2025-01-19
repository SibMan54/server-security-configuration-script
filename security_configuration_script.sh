#!/bin/bash

# Проверяем, запущен ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт от имени root."
  exit 1
fi

echo ""

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

echo ""

# Копирование публичного ключа SSH в папку пользователя
# Путь к вашему публичному SSH-ключу
KEY_PATH="/root/.ssh/authorized_keys"

# Путь к папке назначения (например, в .ssh)
USER_KEY_PATH="/home/$username/.ssh/"
# Создаем папку ssh
mkdir -p "$USER_KEY_PATH"
chmod 700 "$USER_KEY_PATH"
chown $username:$username "$USER_KEY_PATH"

# Проверка, существует ли публичный ключ
if [[ ! -f "$KEY_PATH" ]]; then
    echo "Публичный SSH ключ не найден: $KEY_PATH"
    # Добавление ключа вручную
    echo "Вставьте свой публичный SSH ключ, нажмите Ctrl + X, затем Y и Enter для сохранения."
    read -p "Нажмите Enter для редактирования файла SSH ключа..."
    nano "$USER_KEY_PATH"/authorized_keys
    chmod 600 "$USER_KEY_PATH"/authorized_keys
    chown $username:$username "$USER_KEY_PATH"/authorized_keys
    echo "Публичный SSH ключ успешно добавлен в: $USER_KEY_PATH"
else
    # Проверка, существует ли публичный ключ в папке пользователя
    if [[ ! -f "$USER_KEY_PATH"/authorized_keys ]]; then
      # Копируем публичный ключ в папку назначения
      if cp -f "$KEY_PATH" "$USER_KEY_PATH"; then
          chmod 600 "$USER_KEY_PATH"/authorized_keys
          chown $username:$username "$USER_KEY_PATH"/authorized_keys
          echo "Публичный SSH ключ успешно скопирован в: $USER_KEY_PATH"
      else
          echo "Ошибка при копировании публичного SSH ключа."
          exit 1
      fi
    else
        echo "Публичный ключ в папке $USER_KEY_PATH уже существует!"
        # Резервная копия исходного файла ssh ключа
        if cp $USER_KEY_PATH/authorized_keys $USER_KEY_PATH/authorized_keys.bak; then
            echo "Сделали бэкап существующего ключа в $USER_KEY_PATH/authorized_keys.bak"
        else
            echo "Ошибка при создании резервной копии существующего ssh ключа"
            exit 1
        fi
        # Копируем публичный ключ в папку назначения
        if cp -f "$KEY_PATH" "$USER_KEY_PATH"; then
            chmod 600 "$USER_KEY_PATH"/authorized_keys
            chown $username:$username "$USER_KEY_PATH"/authorized_keys
            echo "Публичный SSH ключ успешно скопирован в: $USER_KEY_PATH"
        else
            echo "Ошибка при копировании публичного SSH ключа."
            exit 1
        fi
    fi
fi

# Проверка SSH соединения для нового пользователя
echo ""
echo "Перед тем как продолжить, попробуйте подключиться к серверу под пользователем $username"
echo ""
read -p "Получилось ли у вас подключиться по SSH от имени пользователя $username ? (y/n): " answer
if [[ "$answer" == "y" ]]; then
    # Редактируем файлы конфигурации ssh
    # Запрос порта у пользователя
    echo ""
    read -p "Введите желаемый порт SSH (по умолчанию 2222): " NEW_PORT
    NEW_PORT=${NEW_PORT:-2222}  # Используем 2222, если пользователь не ввел ничего

    # Путь к файлу конфигурации SSH
    SSH_CONFIG="/etc/ssh/sshd_config"

    # Резервная копия исходного файла конфигурации
    cp $SSH_CONFIG ${SSH_CONFIG}.bak

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

    echo "Защита SSH-соединения настроена. Порт изменен на $NEW_PORT, вход root-пользователю и вход по паролю запрещены."

else
    echo "Защита SSH-соединения НЕ настроена, повторите попытку"
    exit 0
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

# Перезагрузка службы SSH
# systemctl restart ssh
service ssh restart

# Активация автоматических обновлений
echo ""
read -p "Вы хотите включить автоматическое обновление ? (y/n): " answer
if [[ "$answer" == "y" ]]; then
    if systemctl is-active --quiet unattended-upgrades; then
        echo "Автоматическое обновление уже включено"
    else
        # включаем автообновления
        bash <(curl -Ls https://raw.githubusercontent.com/SibMan54/server-security-configuration-script/refs/heads/main/auto_updates_enable.sh)
    fi
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
echo "2. Конфигурация SSH успешно изменена, порт изменен на $NEW_PORT. Используйте его при следующем подключении к серверу."
ufw_status=$(ufw status | grep -i "")
if [[ "$ufw_status" == *"inactive"* ]]; then
  echo "3. Firewall не активирован."
else echo "3. Firewall активирован, порт SSH $NEW_PORT добавлен в список разрешенных."
fi
echo "   Настройка завершена, сервер теперь в безопастности!"
echo "   Чтобы изменения вступили в силу, нужно перезагрузить сервер командой «reboot»."
echo "==========================================================="
