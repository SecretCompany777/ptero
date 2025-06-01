#!/bin/bash
set -e

echo "======================================="
echo "🛠  Pterodactyl Panel Localhost Installer with PHP 8.2 + SSL + Wings"
echo "======================================="

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

# --- PASANG DEPENDENSI ---
echo "🔍 Memeriksa dan memasang dependensi..."

check_and_install() {
    if ! dpkg -l | grep -qw "$1"; then
        echo "📦 Memasang $1..."
        sudo apt install -y "$1"
    else
        echo "✅ $1 telah dipasang."
    fi
}

sudo apt update && sudo apt upgrade -y

# Pakej asas
for pkg in curl git unzip nginx mariadb-server redis-server software-properties-common apt-transport-https ca-certificates gnupg lsb-release; do
    check_and_install "$pkg"
done

# --- PASANG PHP 8.2 DAN MODULE ---
if ! php -v | grep -q "PHP 8.2"; then
    echo "➕ Menambah PPA PHP 8.2..."
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update
fi

for phppkg in php8.2 php8.2-cli php8.2-fpm php8.2-mysql php8.2-mbstring php8.2-xml php8.2-curl php8.2-zip php8.2-bcmath php8.2-fileinfo php8.2-gd php8.2-opcache; do
    check_and_install "$phppkg"
done

# --- Setup Database ---
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

if [ ! -f .env ]; then
    cp .env.example .env
fi

# --- COMPOSER INSTALL ---
if [ ! -d "vendor" ]; then
    echo "📦 Menjalankan composer install..."
    composer install --no-dev --optimize-autoloader --no-interaction
else
    echo "✅ Vendor sudah ada, melangkau composer install..."
fi

# --- KONFIGURASI .env ---
echo "⚙️ Mengemaskini konfigurasi .env..."
sed -i "s|APP_URL=.*|APP_URL=https://localhost|" .env
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
    echo "✅ Akaun admin sudah wujud, melangkau..."
fi

# --- Buat SSL Self-Signed untuk localhost ---
echo "🔐 Menyediakan SSL self-signed untuk localhost..."
sudo mkdir -p /etc/nginx/ssl
if [ ! -f /etc/nginx/ssl/localhost.key ] || [ ! -f /etc/nginx/ssl/localhost.crt ]; then
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/localhost.key \
      -out /etc/nginx/ssl/localhost.crt \
      -subj "/C=MY/ST=Selangor/L=Shah Alam/O=MyOrg/OU=IT/CN=localhost"
fi

# --- NGINX CONFIG with SSL ---
if [ ! -f /etc/nginx/sites-available/pterodactyl ]; then
    echo "🌐 Menyediakan konfigurasi NGINX dengan SSL..."
    sudo tee /etc/nginx/sites-available/pterodactyl > /dev/null <<EOL
server {
    listen 80;
    server_name localhost;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name localhost;

    root /var/www/panel/public;
    index index.php index.html;

    ssl_certificate /etc/nginx/ssl/localhost.crt;
    ssl_certificate_key /etc/nginx/ssl/localhost.key;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL
    sudo ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
fi

sudo nginx -t && sudo systemctl restart nginx

# --- INSTALL WINGS (PTERODACTYL DAEMON) ---
echo "🚀 Memasang Wings (Pterodactyl Daemon)..."

if ! command -v wings &> /dev/null; then
    curl -Lo wings.tar.gz https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64.tar.gz
    tar -xzvf wings.tar.gz
    sudo mv wings /usr/local/bin/wings
    rm wings.tar.gz

    sudo useradd -r -m -d /var/lib/wings wings || true

    sudo mkdir -p /etc/wings /var/lib/wings

    sudo chown -R wings:wings /etc/wings /var/lib/wings
fi

echo "✅ Semua proses selesai! Panel boleh diakses di https://localhost"

echo "======================================="
echo "🛠 PTERODACTYL PANEL + WINGS SIAP DIPASANG!"
echo "======================================="
