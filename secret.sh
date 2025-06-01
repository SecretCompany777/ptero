#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

echo "======================================="
echo "🛠  Pterodactyl Panel Localhost Installer"
echo "======================================="

# --- INPUT PENGGUNA ---
read -rp "Nama penuh admin        : " FULLNAME
read -rp "Username admin (login)  : " USERNAME
read -rp "Email admin             : " EMAIL
read -rsp "Password admin          : " PASSWORD
echo ""

# --- DEFAULT DATABASE CONFIG ---
DB_USER="ptero"
DB_PASS="p@ssw0rd"
DB_NAME="panel"

# --- FUNCTIONS ---
check_and_install() {
    if ! dpkg -s "$1" >/dev/null 2>&1; then
        echo "📦 Memasang $1..."
        sudo apt install -y "$1"
    else
        echo "✅ $1 telah dipasang."
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- UPDATE SISTEM ---
echo "🔄 Mengemas kini sistem..."
sudo apt update && sudo apt upgrade -y

# --- PASANG DEPENDENSI ---
echo "🔍 Memeriksa dan memasang dependensi..."
for pkg in curl git unzip nginx mariadb-server redis-server software-properties-common jq certbot python3-certbot-nginx mysql-client; do
    check_and_install "$pkg"
done

# --- PASANG PPA PHP 8.2 JIKA BELUM ADA ---
if ! php -v 2>/dev/null | grep -q "PHP 8.2"; then
    echo "➕ Menambah PPA PHP 8.2..."
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update
fi

# --- PASANG PHP 8.2 DAN MODULE ---
for phppkg in php8.2 php8.2-cli php8.2-fpm php8.2-mysql php8.2-mbstring php8.2-xml php8.2-curl php8.2-zip php8.2-bcmath php8.2-tokenizer php8.2-ctype php8.2-json php8.2-common; do
    check_and_install "$phppkg"
done

# --- PASTIKAN PHP-FPM BERJALAN ---
echo "🔧 Memastikan PHP-FPM berjalan..."
sudo systemctl enable --now php8.2-fpm

# --- SETUP DATABASE ---
echo "🗃️ Menyediakan pangkalan data..."
sudo systemctl enable --now mariadb

# Amankan MariaDB root password (kalau belum):
sudo mysql_secure_installation || true

# Buat database & user:
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

# --- PASANG COMPOSER JIKA TIADA ---
if ! command_exists composer; then
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
    sudo chown -R "$USER":"$USER" /var/www/panel
fi
cd /var/www/panel

# --- COPY .env JIKA BELUM ADA ---
if [ ! -f .env ]; then
    cp .env.example .env
fi

# --- PASTIKAN PERMISSION betul ---
chmod 640 .env
chown "$USER":"$USER" .env

# --- COMPOSER INSTALL ---
if [ ! -d "vendor" ]; then
    echo "📦 Menjalankan composer install..."
    composer install --no-dev --optimize-autoloader
else
    echo "✅ Direktori vendor telah wujud. Melangkau composer install..."
fi

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
    php artisan p:user:make --email="${EMAIL}" --username="${USERNAME}" --password="${PASSWORD}" --admin=1
else
    echo "✅ Akaun admin telah wujud. Melangkau..."
fi

# --- SETUP NGINX ---
echo "🌐 Menyediakan konfigurasi NGINX..."
NGINX_CONF="/etc/nginx/sites-available/pterodactyl"
if [ ! -f "$NGINX_CONF" ]; then
    sudo tee "$NGINX_CONF" > /dev/null <<EOL
server {
    listen 80;
    server_name localhost;

    root /var/www/panel/public;
    index index.php index.html;

    access_log /var/log/nginx/pterodactyl_access.log;
    error_log /var/log/nginx/pterodactyl_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL
    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
fi

# Buang default nginx config untuk elak clash
if [ -f /etc/nginx/sites-enabled/default ]; then
    sudo rm /etc/nginx/sites-enabled/default
fi

echo "🔍 Memeriksa konfigurasi NGINX..."
sudo nginx -t

echo "♻️ Memulakan semula NGINX..."
sudo systemctl restart nginx

# --- PASANG WINGS (DAEMON PTERODACTYL) ---
echo "🚀 Memasang Wings daemon..."
if ! command_exists wings; then
    curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o wings
    chmod +x wings
    sudo mv wings /usr/local/bin/wings

    # Setup systemd service
    sudo tee /etc/systemd/system/wings.service > /dev/null <<EOL
[Unit]
Description=Pterodactyl Wings Daemon
After=network.target

[Service]
User=$USER
WorkingDirectory=/var/lib/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=600
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOL

    sudo mkdir -p /var/lib/pterodactyl
    sudo chown -R "$USER":"$USER" /var/lib/pterodactyl

    sudo systemctl daemon-reload
    sudo systemctl enable --now wings
else
    echo "✅ Wings daemon telah dipasang."
fi

# --- PASANG SSL dengan Certbot (Let’s Encrypt) ---
echo "🔐 Memasang SSL (Let's Encrypt)..."
if ! sudo certbot certificates | grep -q "localhost"; then
    if ! sudo certbot --nginx -d localhost --non-interactive --agree-tos -m "$EMAIL" --redirect; then
        echo "⚠️ Gagal pasang SSL untuk localhost, mungkin domain 'localhost' tidak sesuai untuk sertifikat SSL."
        echo "    Anda boleh gunakan self-signed cert atau skip SSL untuk localhost."
    fi
else
    echo "✅ SSL certificate untuk localhost sudah ada."
fi

# --- MAKLUMAT SIAP ---
echo ""
echo "======================================="
echo "✅ PTERODACTYL PANEL TELAH DIPASANG!"
echo "🌐 URL     : http://localhost"
echo "👤 Nama    : ${FULLNAME}"
echo "🆔 Username: ${USERNAME}"
echo "📧 Email   : ${EMAIL}"
echo "🔐 Password: (disembunyikan untuk keselamatan)"
echo "======================================="
