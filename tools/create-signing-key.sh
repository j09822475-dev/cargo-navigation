#!/usr/bin/env bash
# Создаёт постоянный ключ подписи Android и печатает значения для GitHub Secrets.
# Запускать ОДИН РАЗ на своём компьютере (нужна Java: keytool). Файл ключа храните в надёжном месте:
# потеряете ключ — придётся один раз удалить приложение с телефона и поставить заново.
set -euo pipefail

OUT="${1:-cargonav-release.jks}"
ALIAS="cargonav"
PASS="$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')"

if [ -e "$OUT" ]; then echo "Файл $OUT уже существует — выберите другое имя: $0 имя.jks" >&2; exit 1; fi

keytool -genkeypair -keystore "$OUT" -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 36500 \
  -storepass "$PASS" -keypass "$PASS" -dname "CN=Cargo Navigation, O=Cargo Navigation, C=RU" >/dev/null

cat <<MSG

Ключ создан: $OUT   (сохраните этот файл!)

Добавьте в GitHub: репозиторий → Settings → Secrets and variables → Actions → New repository secret

  ANDROID_KEYSTORE_BASE64   = (содержимое строки ниже)
  ANDROID_KEYSTORE_PASSWORD = $PASS
  ANDROID_KEY_ALIAS         = $ALIAS
  ANDROID_KEY_PASSWORD      = $PASS

ANDROID_KEYSTORE_BASE64:
$(base64 < "$OUT" | tr -d '\n')

MSG
