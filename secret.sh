#!/bin/bash
set -euo pipefail

echo "======================================="
echo "🛠  Pterodactyl Panel Localhost Installer"
echo "======================================="

# --- INPUT PENGGUNA ---
read -rp "Nama penuh admin        : " FULLNAME
read -rp "Username admin (login)  : " USERNAME
read -rp "Email admin             : " EMAIL
read -rs -p "Password admin          : " PASSWORD
echo ""

# --- DEFAULT DATABASE CONFIG ---
DB_USER="ptero"
DB_PASS="p@ssw0rd"
DB_NAME="panel"

# --- FUNCTION: PASANG PAKET JIKA TIADA ---
check_and_install() {
    if ! dpkg -s "$1" &>/dev/null; then
        echo "📦 Memasang $1..."
        sudo apt-get install -y "$1"
    else
        echo "✅ $1 telah dipasang."
    fi
}

# --- UPDATE SISTEM ---
echo "🔄 Mengemas kini sistem..."
sudo apt-get update -y
sudo apt-get upgrade -y

# --- PASANG DEPENDENSI ---
for pkg in curl git unzip nginx mariadb-server mariadb-client redis-server software-properties-common jq certbot python3-certbot-nginx php8.2 php8.2-cli php8.2-fpm php8.2-mysql php8.2-mbstring php8.2-xml php8.2-curl php8.2-zip php8.2-bcmath; do
    check_and_install "$pkg"
done

# --- SETUP DATABASE ---
echo "🗃️ Menyediakan pangkalan data..."
sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';"
sudo mysql -e "FLUSH PRIVILEGES;"

# --- PASANG COMPOSER ---
if ! command -v composer &>/dev/null; then
    echo "📦 Memasang Composer..."
    curl -sS https://getcomposer.org/installer | php
    sudo mv composer.phar /usr/local/bin/composer
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

# --- COPY .env JIKA BELUM ADA ---
if [ ! -f .env ]; then
    cp .env.example .env
fi

# --- INSTALL DEPENDENCY PANEL ---
if [ ! -d vendor ]; then
    echo "📦 Menjalankan composer install..."
    composer install --no-dev --optimize-autoloader
else
    echo "✅ Direktori vendor sudah ada, langkau composer install."
fi

# --- KEMASKINI KONFIGURASI .env ---
sed -i "s|APP_URL=.*|APP_URL=http://localhost|" .env
sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env

# --- RUN ARTISAN MIGRATE & SEED ---
php artisan key:generate --force
php artisan migrate --seed --force

# --- BUAT ADMIN USER ---
if ! php artisan p:user:list | grep -q "$EMAIL"; then
    php artisan p:user:make --email="$EMAIL" --username="$USERNAME" --password="$PASSWORD" --admin=1
else
    echo "✅ Akaun admin sudah ada, langkau."
fi

# --- SETUP NGINX ---
if [ ! -f /etc/nginx/sites-available/pterodactyl ]; then
    echo "🌐 Setup konfigurasi NGINX..."
    sudo tee /etc/nginx/sites-available/pterodactyl > /dev/null <<'EOF'
server {
    listen 80;
    server_name localhost;

    root /var/www/panel/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    sudo ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
fi

sudo nginx -t
sudo systemctl reload nginx

# --- PASANG WINGS DAEMON ---
if [ ! -f /usr/local/bin/wings ]; then
    echo "🚀 Memasang Wings daemon..."
    curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o wings
    chmod +x wings
    sudo mv wings /usr/local/bin/wings

    sudo mkdir -p /var/lib/pterodactyl
    sudo chown -R $USER:$USER /var/lib/pterodactyl

    sudo tee /etc/systemd/system/wings.service > /dev/null <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=network.target

[Service]
User=$USER
WorkingDirectory=/var/lib/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitIntervalSec=600
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now wings
else
    echo "✅ Wings daemon sudah dipasang."
fi

# --- PASANG SSL (certbot) ---
echo "🔐 Setup SSL (Let's Encrypt)..."
if ! sudo certbot certificates | grep -q "localhost"; then
    sudo certbot --nginx -d localhost --non-interactive --agree-tos -m "$EMAIL" --redirect || echo "⚠️ Gagal pasang SSL untuk localhost, abaikan jika guna localhost."
else
    echo "✅ SSL certificate untuk localhost sudah ada."
fi

echo ""
echo "======================================="
echo "✅ PTERODACTYL PANEL TELAH DIPASANG!"
echo "🌐 URL     : http://localhost"
echo "👤 Nama    : ${FULLNAME}"
echo "🆔 Username: ${USERNAME}"
echo "📧 Email   : ${EMAIL}"
echo "🔐 Password: ${PASSWORD}"
echo "======================================="
