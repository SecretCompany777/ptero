#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

# =======================================
echo "\n🛠  Pterodactyl Panel Localhost Installer"
echo "=======================================\n"

# --- INPUT PENGGUNA ---
read -p "Nama penuh admin        : " FULLNAME
read -p "Username admin (login)  : " USERNAME
read -p "Email admin             : " EMAIL
read -s -p "Password admin          : " PASSWORD
echo ""

# --- DEFAULT DATABASE CONFIG ---
DB_USER="ptero"
DB_PASS="p@ssw0rd"
DB_NAME="panel"

# --- MEMERIKSA DAN PASANG DEPENDENSI ---
echo "🔍 Memeriksa dan memasang dependensi..."

check_and_install() {
    if ! dpkg -l | grep -q "^ii  $1 "; then
        echo "📦 Memasang $1..."
        sudo apt install -y "$1"
    else
        echo "✅ $1 telah dipasang."
    fi
}

sudo apt update && sudo apt upgrade -y

for pkg in curl git unzip nginx mariadb-server redis-server software-properties-common; do
    check_and_install "$pkg"
done

# --- PPA PHP 8.1 ---
if ! php -v | grep -q "PHP 8.1"; then
    echo "➕ Menambah PPA PHP 8.1..."
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update
fi

# --- PASANG PHP 8.1 DAN EXTENSION YANG DIPERLUKAN ---
PHP_MODULES=(
    php8.1 php8.1-cli php8.1-fpm php8.1-mysql php8.1-mbstring \
    php8.1-xml php8.1-curl php8.1-zip php8.1-bcmath php8.1-gd \
    php8.1-tokenizer php8.1-common php8.1-readline php8.1-fileinfo
)

for phppkg in "${PHP_MODULES[@]}"; do
    check_and_install "$phppkg"
done

# --- SETUP DATABASE ---
echo "🗃️ Menyediakan pangkalan data..."
sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';"
sudo mysql -e "FLUSH PRIVILEGES;"

# --- PASANG COMPOSER ---
if ! command -v composer &> /dev/null; then
    echo "📦 Memasang Composer..."
    curl -sS https://getcomposer.org/installer | php
    sudo mv composer.phar /usr/local/bin/composer
    composer --version
else
    echo "✅ Composer telah dipasang."
fi

# --- MUAT TURUN PANEL ---
if [ ! -d /var/www/panel ]; then
    echo "⬇️ Memuat turun Pterodactyl Panel..."
    sudo git clone https://github.com/pterodactyl/panel.git /var/www/panel
    sudo chown -R $USER:$USER /var/www/panel
fi
cd /var/www/panel

# --- COPY .env ---
if [ ! -f .env ]; then
    sudo cp .env.example .env
fi

# --- COMPOSER INSTALL ---
echo "📦 Menjalankan composer install..."
composer install --no-dev --optimize-autoloader --no-interaction

# --- KONFIGURASI .env ---
echo "⚙️ Mengemaskini konfigurasi .env..."
sed -i "s|APP_URL=.*|APP_URL=http://localhost|" .env
sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env

# --- ARTISAN SETUP ---
echo "🛠 Menjalankan artisan setup..."
php artisan key:generate --force
php artisan migrate --seed --force

# --- CIPTA ADMIN ---
echo "👤 Mencipta admin ${EMAIL} (${USERNAME})..."
if ! php artisan p:user:list | grep -q "$EMAIL"; then
    php artisan p:user:make --email="${EMAIL}" --username="${USERNAME}" --name="${FULLNAME}" --password="${PASSWORD}" --admin=1
else
    echo "✅ Akaun admin telah wujud. Melangkau..."
fi

# --- SETUP NGINX ---
if [ ! -f /etc/nginx/sites-available/pterodactyl ]; then
    echo "🌐 Menyediakan NGINX config..."
    sudo tee /etc/nginx/sites-available/pterodactyl > /dev/null <<EOL
server {
    listen 80;
    server_name localhost;

    root /var/www/panel/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL
    sudo ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
fi

sudo nginx -t && sudo systemctl restart nginx

# --- MAKLUMAT SIAP ---
echo ""
echo "======================================="
echo "✅ PTERODACTYL PANEL TELAH DIPASANG!"
echo "🌐 URL     : http://localhost"
echo "👤 Nama    : ${FULLNAME}"
echo "🆔 Username: ${USERNAME}"
echo "📧 Email   : ${EMAIL}"
echo "🔐 Password: ${PASSWORD}"
echo "======================================="
