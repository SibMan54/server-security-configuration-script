#!/bin/bash

# Проверяем, запущен ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт от имени root."
  exit 1
fi

# Создаем нового пользователя
read -p "Введите имя нового пользователя: " username

# Проверка, существует ли пользователь
if id "$username" &>/dev/null; then
  echo "Пользователь $username уже существует!"
  exit 1
fi

# Создаем нового пользователя
if adduser "$username"; then
  echo "Пользователь $username успешно создан."
else
  echo "Ошибка при создании пользователя $username."
  exit 1
fi

# Выдаем новому пользователю права sudo
if usermod -aG sudo "$username"; then
  echo "Пользователю $username успешно выданы права sudo."
else
  echo "Ошибка при назначении прав sudo пользователю $username."
  exit 1
fi

# Добавление SSH ключа в папку пользователя
echo =======================================================================
echo "Вставьте публичный ключ, нажав правую кнопку мыши, затем Ctrl+X, затем Y и Enter для сохранения".
echo =======================================================================
read -p "Если прочитали, нажимайте Enter и приступайте"
mkdir /home/$username/.ssh
nano /home/$username/.ssh/authorized_keys

# Редактируем файлы конфигурации ssh

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

echo ===========================
echo "Конфигурация SSH успешно изменена. Порт изменен на $NEW_PORT. Новый порт добавлен в ufw."
echo  ++++++++++++++++++++++++++
echo "Настройка завершена, сервер теперь в безопастности!"
echo ===========================
