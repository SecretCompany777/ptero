#!/bin/bash
set -e

echo "======================================="
echo "🛠  Pterodactyl Panel Localhost Installer"
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

# --- PASANG DEPENDENSI (SKIP JIKA SUDAH ADA) ---
echo "🔍 Memeriksa dependensi..."

check_and_install() {
    if ! dpkg -l | grep -q "^ii  $1 "; then
        echo "📦 Memasang $1..."
        sudo apt install -y "$1"
    else
        echo "✅ $1 telah dipasang."
    fi
}

sudo apt update && sudo apt upgrade -y

for pkg in curl git unzip nginx mariadb-server redis-server software-properties-common jq certbot python3-certbot-nginx php8.2 php8.2-cli php8.2-fpm php8.2-mysql php8.2-mbstring php8.2-xml php8.2-curl php8.2-zip php8.2-bcmath; do
    check_and_install "$pkg"
done

# --- PPA PHP 8.2 (pastikan ada) ---
if ! php -v | grep -q "PHP 8.2"; then
    echo "➕ Menambah PPA PHP 8.2..."
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update
fi

# --- SETUP DATABASE ---
echo "🗃️ Menyediakan pangkalan data..."
sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';"
sudo mysql -e "FLUSH PRIVILEGES;"

# --- PASANG COMPOSER JIKA TIADA ---
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
cd /var/www/panel || { echo "❌ Gagal akses ke /var/www/panel"; exit 1; }

# --- COPY .env JIKA BELUM ADA ---
if [ ! -f .env ]; then
    cp .env.example .env
fi

# --- COMPOSER INSTALL JIKA TIADA vendor/ ---
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
ADMIN_EXISTS=$(php artisan tinker --execute="echo App\\Models\\User::where('email', '${EMAIL}')->exists() ? '1' : '0';")
if [ "$ADMIN_EXISTS" != "1" ]; then
    php artisan p:user:make --email="${EMAIL}" --username="${USERNAME}" --password="${PASSWORD}" --admin=1
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
    index index.php;

    access_log /var/log/nginx/pterodactyl_access.log;
    error_log /var/log/nginx/pterodactyl_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL
    sudo ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
fi

sudo nginx -t && sudo systemctl restart nginx

# --- PASANG WINGS (DAEMON PTERODACTYL) ---
if [ ! -f /usr/local/bin/wings ]; then
    echo "🚀 Memasang Wings daemon..."
    curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o wings
    chmod +x wings
    sudo mv wings /usr/local/bin/wings

    # Setup systemd service for wings
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
    sudo chown -R $USER:$USER /var/lib/pterodactyl

    sudo systemctl daemon-reload
    sudo systemctl enable --now wings
else
    echo "✅ Wings daemon telah dipasang."
fi

# --- PASANG SSL dengan Certbot (LetsEncrypt) ---
echo "🔐 Memasang SSL (Let's Encrypt)..."
if ! sudo certbot certificates | grep -q "localhost"; then
    sudo certbot --nginx -d localhost --non-interactive --agree-tos -m "$EMAIL" --redirect || echo "⚠️ Gagal pasang SSL untuk localhost, mungkin domain localhost tidak sesuai."
else
    echo "✅ SSL certificate untuk localhost sudah ada."
fi

# --- DIAGNOSTIK AKHIR UNTUK ERROR "Service Unavailable" ---
echo ""
echo "🔎 Menjalankan diagnostik untuk masalah biasa..."

has_error=false

# 1. Semak status PHP-FPM
echo "🧪 Semakan status PHP-FPM..."
if ! systemctl is-active --quiet php8.2-fpm; then
    echo "❌ PHP-FPM tidak aktif. Cuba menghidupkan semula..."
    sudo systemctl restart php8.2-fpm
    sleep 2
    if ! systemctl is-active --quiet php8.2-fpm; then
        echo "❌ Gagal hidupkan php8.2-fpm. Sila semak dengan:"
        echo "    sudo journalctl -u php8.2-fpm"
        has_error=true
    else
        echo "✅ php8.2-fpm telah berjaya dimulakan."
    fi
else
    echo "✅ php8.2-fpm sedang berjalan."
fi

# 2. Semak permission fail
echo "🧪 Semakan permission folder..."
sudo chown -R www-data:www-data /var/www/panel
sudo chmod -R 755 /var/www/panel
echo "✅ Permission telah dikemaskini ke www-data."

# 3. Semak konfigurasi NGINX
echo "🧪 Semakan konfigurasi NGINX..."
sudo nginx -t
if [ $? -ne 0 ]; then
    echo "❌ Konfigurasi NGINX bermasalah. Sila semak dengan:"
    echo "    sudo nginx -t"
    has_error=true
else
    echo "✅ Konfigurasi NGINX sah."
fi

# 4. Semak log error
echo "🧪 Semakan ringkas log error NGINX dan PHP-FPM..."
sudo tail -n 10 /var/log/nginx/pterodactyl_error.log || true
sudo journalctl -u php8.2-fpm -n 10 --no-pager || true

echo ""

# --- MAKLUMAT SIAP ---
echo ""
echo "======================================="
if [ "$has_error" = true ]; then
    echo "❌ Beberapa masalah dikesan semasa pemasangan."
    echo "🔧 Sila ikut cadangan di atas atau semak log untuk maklumat lanjut."
else
    echo "✅ PTERODACTYL PANEL TELAH DIPASANG DENGAN JAYANYA!"
    echo "🌐 URL     : http://localhost"
    echo "👤 Nama    : ${FULLNAME}"
    echo "🆔 Username: ${USERNAME}"
    echo "📧 Email   : ${EMAIL}"
    echo "🔐 Password: ${PASSWORD}"
    echo "SILA BUKA http://localhost DALAM PELAYAR ANDA UNTUK MENGAKSES PANEL."
fi
echo "======================================="
