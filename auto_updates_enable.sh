
#!/bin/bash

# Проверяем наличие пакета unattended-upgrades
if ! which unattended-upgrades > /dev/null 2>&1; then
    echo "Установка unattended-upgrades..."
    apt update && apt install unattended-upgrades -y
else
    echo "unattended-upgrades уже установлен."
fi

# Настройка unattended-upgrades
echo "Конфигурация unattended-upgrades..."
dpkg-reconfigure --priority=low unattended-upgrades

# Редактируем конфигурационный файл
CONF_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"
echo "Редактируем файл конфигурации $CONF_FILE"
sed -i 's|^\s*"\${distro_id}:\${distro_codename}";|//      "${distro_id}:${distro_codename}";|g' $CONF_FILE
sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|g' $CONF_FILE

# Проверяем файл 20auto-upgrades
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
echo "Включаем ежедневные обновления в $AUTO_UPGRADES_FILE..."
if ! grep -q "APT::Periodic::Update-Package-Lists" $AUTO_UPGRADES_FILE; then
    echo 'APT::Periodic::Update-Package-Lists "1";' >> $AUTO_UPGRADES_FILE
else
    sed -i 's/^APT::Periodic::Update-Package-Lists.*/APT::Periodic::Update-Package-Lists "1";/' $AUTO_UPGRADES_FILE
fi

if ! grep -q "APT::Periodic::Unattended-Upgrade" $AUTO_UPGRADES_FILE; then
    echo 'APT::Periodic::Unattended-Upgrade "1";' >> $AUTO_UPGRADES_FILE
else
    sed -i 's/^APT::Periodic::Unattended-Upgrade.*/APT::Periodic::Unattended-Upgrade "1";/' $AUTO_UPGRADES_FILE
fi

# Запуск и включение службы unattended-upgrades
systemctl start unattended-upgrades
systemctl enable unattended-upgrades

# Проверка статуса службы
if systemctl is-active --quiet unattended-upgrades; then
    echo "Служба unattended-upgrades запущена."
else
    echo "Служба unattended-upgrades не запущена."
fi
