#!/usr/bin/env bash
# Создаёт постоянный ключ подписи Android и файл со значением секрета GitHub ANDROID_SIGNING_KEY.
# Запускать ОДИН РАЗ (нужна Java: keytool). Файл с секретом храните в надёжном месте:
# потеряете ключ — придётся один раз удалить приложение с телефона и поставить заново.
set -euo pipefail

OUT_DIR="${1:-.}"
JKS="$OUT_DIR/cargonav-release.jks"
SECRET="$OUT_DIR/ANDROID_SIGNING_KEY.txt"
PASS="$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')"

if [ -e "$JKS" ] || [ -e "$SECRET" ]; then echo "В $OUT_DIR уже есть ключ — выберите другую папку: $0 папка" >&2; exit 1; fi
mkdir -p "$OUT_DIR"

keytool -genkeypair -keystore "$JKS" -storetype PKCS12 -alias cargonav -keyalg RSA -keysize 2048 -validity 36500 \
  -storepass "$PASS" -keypass "$PASS" -dname "CN=Cargo Navigation, O=Cargo Navigation, C=EE" >/dev/null 2>&1

# значение секрета: первая строка — пароль, дальше — файл ключа в base64
{ echo "$PASS"; base64 < "$JKS"; } > "$SECRET"
chmod 600 "$JKS" "$SECRET"

cat <<MSG
Готово:
  $SECRET — значение секрета (и резервная копия ключа)
  $JKS — сам ключ

Добавьте в GitHub: репозиторий → Settings → Secrets and variables → Actions → New repository secret
  Name:   ANDROID_SIGNING_KEY
  Secret: всё содержимое файла $SECRET
MSG
