#!/bin/bash

# Проверяем, запущен ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт от имени root."
  exit 1
fi

# Создаем нового пользователя
read -p "Введите имя нового пользователя: "
adduser "$username"

# Выдаем новому пользователю права sudo
usermod -aG sudo "$username"

# Редактируем файлы конфигурации ssh
echo "Редактируйте файлы конфигурации ssh. Нажмите Ctrl + X, затем Y и Enter для сохранения."
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
