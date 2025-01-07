#!/bin/bash

# Проверяем, запущен ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт от имени root."
  exit 1
fi

# Создаем нового пользователя
USER=1
read -p "Введите имя нового пользователя: " username

# Проверка, существует ли пользователь
if id "$username" &>/dev/null; then
  echo "Пользователь $username уже существует!"
  USER=2
fi

case $USER in
1)
# Создаем нового пользователя
if adduser "$username" sudo; then
  echo "Пользователь $username успешно создан."
else
  echo "Ошибка при создании пользователя $username."
  exit 1
fi
;;
2)
# Выдаем новому пользователю права sudo
if usermod -aG "$username" sudo; then
  echo "Пользователю $username успешно выданы права sudo."
else
  echo "Ошибка при назначении прав sudo пользователю $username."
  exit 1
fi
;;
esac

# Копирование публичного ключа SSH в папку пользователя
#
# Путь к вашему публичному SSH-ключу
KEY_PATH="/root/.ssh/authorized_keys"

# Путь к папке назначения (например, в .ssh)
USER_KEY_PATH="/home/$username/.ssh/"
# Создаем папку ssh
mkdir -p "$USER_KEY_PATH"
chmod 700 "$USER_KEY_PATH"

# Проверка, существует ли публичный ключ
if [[ ! -f "$KEY_PATH" ]]; then
    echo "Публичный SSH ключ не найден: $KEY_PATH"
    # Добавление ключа вручную 
    echo "Скопируйте и вставьте свой публичный ключ SSH, нажмите Ctrl + X, затем Y и Enter для сохранения."
    read -p "Нажмите Enter для редактирования файла ключа SSH..."
    nano "$USER_KEY_PATH"/authorized_keys
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


# Редактируем файлы конфигурации ssh
#
# Запрос порта у пользователя
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

# Включаем Firewall и добавляем разрешенные порты
ufw enable
ufw allow $NEW_PORT/tcp
ufw reload
ufw status numbered

# Перезагрузка службы SSH
systemctl restart ssh

echo ===========================================================
echo "Конфигурация SSH успешно изменена. Порт изменен на $NEW_PORT. Новый порт добавлен в ufw."
echo ""
echo "Настройка завершена, сервер теперь в безопастности!"
echo ===========================================================
