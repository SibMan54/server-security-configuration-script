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
  echo "Пользователь $username уже существует. Прекращение работы."
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

# Редактируем файлы конфигурации ssh
echo "Редактируйте файлы конфигурации ssh. Нажмите Ctrl + X, затем Y и Enter для сохранения."
echo - Необходимо найти строку "#Port 22" изменяем к виду Port 4567
echo - Необходимо найти строку "PermitRootLogin yes" мзменяем значение на "no"
echo - Необходимо найти строку "#PubkeyAuthentication yes" убираем "#" 
echo - Необходимо найти строки "#PasswordAuthentication yes" и "#PermitEmptyPasswords no" убираем "#" и меняем значения на "no"
# Пауза перед редактированием файлов конфигурации SSH
read -p "Нажмите Enter для редактирования файлов конфигурации SSH..."
nano /etc/ssh/sshd_config
nano /etc/ssh/sshd_config.d/50-cloud-init.conf

# Перезапускаем ssh
service ssh restart

# Включаем Firewall и добавляем разрешенные порты
ufw enable
ufw allow 443/tcp
ufw allow 4567/tcp
ufw allow 13000/tcp

echo "Настройка завершена!"
