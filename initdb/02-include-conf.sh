#!/bin/bash
# Aktifkan pembacaan folder tuning /etc/postgresql/conf.d (*.conf)
set -euo pipefail
grep -q "^include_dir = '/etc/postgresql/conf.d'" "$PGDATA/postgresql.conf" || \
  echo "include_dir = '/etc/postgresql/conf.d'" >> "$PGDATA/postgresql.conf"
echo ">> include_dir conf.d aktif"
