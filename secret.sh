#!/bin/bash
set -e

echo "======================================="
echo "🛠  Pterodactyl Panel Localhost Installer"
echo "======================================="

# --- USER INPUT ---
read -p "Nama penuh admin        : " FULLNAME
read -p "Username admin (login)  : " USERNAME
read -p "Email admin             : " EMAIL
read -s -p "Password admin          : " PASSWORD
echo ""

# --- SET DEFAULT DB INFO ---
DB_USER="ptero"
DB_PASS="p@ssw0rd"
DB_NAME="panel"

# --- PASANG DEPENDENCIES ---
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git unzip nginx mariadb-server redis-server software-properties-common

# --- TAMBAH PPA UNTUK PHP 8.1 ---
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update

# --- PASANG PHP 8.1 DAN MODULE ---
sudo apt install -y php8.1 php8.1-cli php8.1-fpm php8.1-mysql php8.1-mbstring php8.1-xml php8.1-curl php8.1-zip composer

# --- SETUP MARIA DB ---
sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';"
sudo mysql -e "FLUSH PRIVILEGES;"

# --- MUAT TURUN PANEL ---
cd /var/www
sudo git clone https://github.com/pterodactyl/panel.git
cd panel
sudo cp .env.example .env
sudo composer install --no-dev --optimize-autoloader

# --- KONFIGURASI .env ---
sudo sed -i "s|APP_URL=.*|APP_URL=http://localhost|" .env
sudo sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sudo sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sudo sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sudo sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env

# --- LARAVEL SETUP ---
sudo php artisan key:generate --force
sudo php artisan migrate --seed --force

# --- CIPTA ADMIN ---
echo "👤 Cipta admin ${EMAIL} (${USERNAME})..."
sudo php artisan p:user:make --email="${EMAIL}" --username="${USERNAME}" --name="${FULLNAME}" --password="${PASSWORD}" --admin=1

# --- SETUP NGINX ---
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

sudo ln -s /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/ || true
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
