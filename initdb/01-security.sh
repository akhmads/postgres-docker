#!/bin/bash
# Dijalankan SEKALI saat volume data pertama kali dibuat.
set -euo pipefail

# ---------- 1. Sertifikat SSL self-signed ----------
CN="${SSL_CN:-localhost}"
if [[ "$CN" =~ ^[0-9.]+$ ]]; then SAN="IP:${CN},DNS:localhost,IP:127.0.0.1"
else SAN="DNS:${CN},DNS:localhost,IP:127.0.0.1"; fi

echo ">> Membuat sertifikat SSL (CN=${CN})"
openssl req -new -x509 -days 3650 -nodes -newkey rsa:4096 \
  -subj "/CN=${CN}" -addext "subjectAltName=${SAN}" \
  -keyout "$PGDATA/server.key" -out "$PGDATA/server.crt" 2>/dev/null
chmod 600 "$PGDATA/server.key"
chmod 644 "$PGDATA/server.crt"

# ---------- 2. Aktifkan SSL + user aplikasi + cabut hak PUBLIC ----------
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_user="$APP_USER" -v app_password="$APP_PASSWORD" -v db="$POSTGRES_DB" <<'EOSQL'
ALTER SYSTEM SET ssl = 'on';

-- User aplikasi: bukan superuser, tidak bisa buat role/database
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 100;

-- App user jadi owner database aplikasi (bisa CREATE TABLE di schema public)
ALTER DATABASE :"db" OWNER TO :"app_user";

-- Role lain tidak bisa connect sembarangan ke database mana pun
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
REVOKE ALL ON DATABASE postgres FROM PUBLIC;
REVOKE ALL ON DATABASE template1 FROM PUBLIC;
EOSQL

echo ">> Hardening selesai"
