# PostgreSQL 18 — Docker Compose

PostgreSQL 18 yang bisa diakses dari jaringan/publik dengan pengamanan bawaan:
SSL wajib, autentikasi `scram-sha-256`, user aplikasi terpisah (non-superuser),
log audit, dan container hardening. Semua konfigurasi diatur lewat file `.env`.

## Struktur

```
.
├── docker-compose.yml          # definisi service
├── .env                        # konfigurasi + password (JANGAN di-commit)
├── .env.example                # template .env
├── config/
│   ├── pg_hba.conf             # aturan siapa boleh connect dari mana
│   └── conf.d/
│       └── 10-pgtune.conf      # tuning performa (tempel hasil pgtune di sini)
└── initdb/                     # dijalankan SEKALI saat volume pertama dibuat
    ├── 01-security.sh          # sertifikat SSL, user aplikasi, cabut hak PUBLIC
    └── 02-include-conf.sh      # aktifkan pembacaan config/conf.d/
```

## Quick start

```bash
cp .env.example .env
# Edit .env: isi POSTGRES_PASSWORD, APP_PASSWORD, SSL_CN
# Generate password kuat:  openssl rand -base64 32 | tr -d '/+=' | cut -c1-32
chmod 600 .env

docker compose up -d
docker compose ps        # tunggu status "healthy"
```

## Konfigurasi `.env`

| Variabel | Keterangan |
|---|---|
| `POSTGRES_VERSION` | Tag image, default `18` (dapat patch minor saat `pull`) |
| `CONTAINER_NAME` | Nama container; volume data bernama `<CONTAINER_NAME>_data` |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | Superuser. Hindari nama `postgres` |
| `POSTGRES_DB` | Database aplikasi |
| `APP_USER` / `APP_PASSWORD` | User untuk aplikasi (bukan superuser), owner `POSTGRES_DB` |
| `POSTGRES_BIND_ADDRESS` | `0.0.0.0` = semua interface (publik), `127.0.0.1` = lokal saja |
| `POSTGRES_PORT` | Port di host (default `5433`; `5432` dipakai PostgreSQL 17) |
| `PG_SHM_SIZE` | Ukuran `/dev/shm`; naikkan bila pakai parallel query besar |
| `SSL_CN` | Hostname/IP untuk sertifikat SSL self-signed |
| `TZ` | Zona waktu, mis. `Asia/Jakarta` |

> **Penting:** `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `APP_*`, dan
> `SSL_CN` **hanya dipakai saat volume pertama kali dibuat**. Mengubahnya
> setelah itu tidak berpengaruh — lihat [Ganti password](#ganti-password).

## Koneksi

SSL wajib; koneksi tanpa SSL ditolak.

```
# Aplikasi (disarankan)
postgresql://app_user:<APP_PASSWORD>@<HOST>:5433/appdb?sslmode=require

# Admin
psql "host=<HOST> port=5433 user=admin dbname=appdb sslmode=require"

# Dari dalam container (tanpa password)
docker exec -it postgres18 psql -U admin -d appdb
```

Untuk verifikasi sertifikat server (mencegah man-in-the-middle):

```bash
docker exec postgres18 cat /var/lib/postgresql/18/docker/server.crt > server.crt
psql "host=<HOST> port=5433 user=app_user dbname=appdb sslmode=verify-ca sslrootcert=server.crt"
```

## Tuning performa (pgtune)

1. Buka <https://pgtune.leopard.in.ua/>, isi spesifikasi. Jika server dipakai
   bersama service lain, isi RAM/CPU **sesuai jatah** untuk PostgreSQL saja.
2. Tempel hasilnya ke `config/conf.d/10-pgtune.conf` (ganti isinya).
3. `docker restart postgres18`
4. Cek: `docker exec postgres18 psql -U admin -d appdb -c "show shared_buffers"`

Semua file `*.conf` di `config/conf.d/` dibaca urut abjad; file terakhir menang
bila ada setting yang sama. Setting keamanan (`listen_addresses`, `hba_file`,
`ssl`, `password_encryption`, logging) dikunci di `docker-compose.yml` dan
tidak bisa ditimpa dari `conf.d`.

Cek dari mana sebuah setting berasal:

```sql
SELECT name, setting, unit, source, sourcefile
FROM pg_settings WHERE name IN ('shared_buffers', 'work_mem', 'max_connections');
```

## Keamanan

### Yang sudah diterapkan

- **SSL wajib** (TLS ≥ 1.2) — `hostnossl ... reject` di `pg_hba.conf`
- **scram-sha-256** untuk semua password
- **User aplikasi non-superuser** — tidak bisa `CREATE ROLE`/`CREATE DATABASE`,
  limit 100 koneksi
- **Hak `PUBLIC` dicabut** dari `appdb`, `postgres`, `template1`
- **Log audit** — koneksi (user, DB, IP, status SSL), login gagal, perubahan
  skema (DDL). Lihat: `docker logs postgres18`
- **Container hardening** — `cap_drop: ALL` + capability minimal,
  `no-new-privileges`, rotasi log (5 × 10MB)
- **Username superuser non-default** (bukan `postgres`)

### Yang perlu dilakukan manual

**1. Batasi IP klien** (paling efektif). Edit `config/pg_hba.conf`, ganti
`0.0.0.0/0` dengan IP/CIDR yang diizinkan, lalu `docker restart postgres18`.

**2. Firewall.** Docker mem-bypass `ufw`; gunakan chain `DOCKER-USER`:

```bash
# Hanya izinkan subnet 10.68.68.0/24 ke port 5433
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 5433 \
  ! -s 10.68.68.0/24 -j DROP
```

**3. Superuser hanya dari IP admin.** Aktifkan baris contoh (yang di-comment)
di `config/pg_hba.conf`, atau akses superuser lewat SSH tunnel saja:

```bash
ssh -L 5433:localhost:5433 user@server
psql "host=localhost port=5433 user=admin dbname=appdb sslmode=require"
```

**4. fail2ban** untuk memblokir brute-force — pola log yang bisa dipakai:
`password authentication failed for user "..."` dengan IP di prefix `from <IP>`.

**5. Update rutin:** `docker compose pull && docker compose up -d`

## Operasional

```bash
docker compose up -d                 # start / terapkan perubahan compose/.env
docker restart postgres18            # terapkan perubahan pg_hba.conf / conf.d
docker logs -f postgres18            # lihat log
docker compose down                  # stop (data aman di volume)
docker compose down -v               # stop + HAPUS SEMUA DATA
```

Reload tanpa restart (untuk `pg_hba.conf` dan setting yang tidak butuh restart):

```bash
docker exec postgres18 psql -U admin -d appdb -c "select pg_reload_conf()"
```

### Ganti password

```bash
docker exec -it postgres18 psql -U admin -d appdb \
  -c "ALTER USER app_user PASSWORD 'password_baru'"
```

Lalu perbarui juga nilainya di `.env` agar tetap sinkron.

### Backup & restore

```bash
# Backup (format custom, terkompresi)
docker exec postgres18 pg_dump -U admin -d appdb -Fc > backup_$(date +%F).dump

# Restore
docker exec -i postgres18 pg_restore -U admin -d appdb --clean --if-exists < backup_2026-11-04.dump

# Backup semua database + role
docker exec postgres18 pg_dumpall -U admin > all_$(date +%F).sql
```

## Troubleshooting

| Gejala | Penyebab / solusi |
|---|---|
| `pg_hba.conf rejects connection ... no encryption` | Klien tidak pakai SSL → tambahkan `sslmode=require` |
| `pg_hba.conf rejects connection for host "x.x.x.x"` | IP klien tidak diizinkan di `pg_hba.conf` |
| `role "postgres" does not exist` | Memang tidak ada; gunakan `-U admin` |
| `permission denied for database` | User tidak punya hak `CONNECT` ke DB tersebut |
| Perubahan `.env` (user/password) tidak berlaku | Hanya berlaku saat init volume; gunakan `ALTER USER` |
| `port is already allocated` | Port dipakai service lain; ganti `POSTGRES_PORT` |
| Setting pgtune tidak berubah | Sudah `docker restart`? Cek `sourcefile` di `pg_settings` |
