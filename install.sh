#!/usr/bin/env bash
# Установщик VPN-бота для 3x-ui. Запуск: sudo bash install.sh
# Данные панели 3x-ui здесь НЕ запрашиваются: их вводят в самом боте командой /setup.
set -euo pipefail

APP_DIR=/opt/vpn-bot
SERVICE=vpn-bot

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите от root: sudo bash $0"; exit 1
fi

ask() { # ask VAR "Вопрос" [значение_по_умолчанию]
  local var=$1 prompt=$2 def=${3:-} val=""
  [ -n "$def" ] && prompt="$prompt [$def]"
  while :; do
    read -r -p "$prompt: " val </dev/tty
    val=${val:-$def}
    [ -n "$val" ] && break
    echo "  Значение не может быть пустым."
  done
  printf -v "$var" '%s' "$val"
}
ask_re() { # ask_re VAR "Вопрос" "regex" "сообщение об ошибке" [по_умолчанию]
  local var=$1 prompt=$2 re=$3 msg=$4 def=${5:-}
  while :; do
    ask "$var" "$prompt" "$def"
    [[ ${!var} =~ $re ]] && break
    echo "  $msg"
  done
}
esc() { printf '%s' "${1//\'/\\\'}"; }
tg_ok() { curl -fsS --max-time 15 "https://api.telegram.org/bot$1/getMe" 2>/dev/null | grep -q '"ok":true'; }

echo "==> Установка системных пакетов"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip curl ca-certificates
elif command -v dnf >/dev/null; then
  dnf install -y python3 python3-pip curl ca-certificates
elif command -v yum >/dev/null; then
  yum install -y python3 python3-pip curl ca-certificates
else
  echo "Неподдерживаемая система: нужен apt, dnf или yum"; exit 1
fi

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "Нужен Python 3.9 или новее (например, Ubuntu 22.04+ или Debian 11+)."; exit 1
fi

echo "==> Распаковка файлов бота в $APP_DIR"
mkdir -p "$APP_DIR"
SELF="$(readlink -f "$0")"
sed '1,/^__PAYLOAD__$/d' "$SELF" | base64 -d | tar xz -C "$APP_DIR"

if [ ! -f "$APP_DIR/.env" ]; then
  echo
  echo "==> Настройка бота (потом всё можно поменять в $APP_DIR/.env)"
  while :; do
    ask BOT_TOKEN "Токен бота от @BotFather"
    if tg_ok "$BOT_TOKEN"; then echo "    Токен принят."; break; fi
    ask FORCE "Токен не прошёл проверку (или сервер не достучался до Telegram). Использовать всё равно? (y/n)" "n"
    [[ $FORCE =~ ^[Yy] ]] && break
  done
  ask_re ADMIN_IDS "Ваш Telegram ID (узнать: бот @userinfobot; несколько ID — через запятую)" \
    '^[0-9]+(,[0-9]+)*$' "Нужны только цифры."
  ask_re TRIAL_DAYS "Пробный период, дней (0 — отключить)" '^[0-9]+$' "Нужно число." "1"
  TRIAL_GB=5
  if [ "$TRIAL_DAYS" != "0" ]; then
    ask_re TRIAL_GB "Лимит трафика на пробном периоде, ГБ" '^[0-9]+$' "Нужно число." "5"
  fi
  echo "Цены тарифов в Telegram Stars:"
  ask_re PRICE_M1  "  1 месяц"    '^[0-9]+$' "Нужно число." "150"
  ask_re PRICE_M3  "  3 месяца"   '^[0-9]+$' "Нужно число." "400"
  ask_re PRICE_M12 "  12 месяцев" '^[0-9]+$' "Нужно число." "1400"

  {
    echo "BOT_TOKEN='$(esc "$BOT_TOKEN")'"
    echo "ADMIN_IDS=$ADMIN_IDS"
    echo "LIMIT_IP=0"
    echo "TRIAL_DAYS=$TRIAL_DAYS"
    echo "TRIAL_GB=$TRIAL_GB"
    echo "PRICE_M1=$PRICE_M1"
    echo "PRICE_M3=$PRICE_M3"
    echo "PRICE_M12=$PRICE_M12"
  } > "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
else
  echo "==> Найден существующий .env, настройки сохранены"
fi

echo "==> Установка Python-зависимостей"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip -q
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q

echo "==> Создание службы systemd"
cat > /etc/systemd/system/$SERVICE.service <<UNIT
[Unit]
Description=VPN Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python bot.py
Restart=always
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable $SERVICE >/dev/null 2>&1
systemctl restart $SERVICE
sleep 3
[ -f "$APP_DIR/bot.db" ] && chmod 600 "$APP_DIR/bot.db"

echo
if systemctl is-active --quiet $SERVICE; then
  echo "✅ Бот установлен и запущен, после перезагрузки сервера стартует сам."
  echo
  echo "ЧТО ДАЛЬШЕ: откройте своего бота в Telegram, отправьте /start, затем /setup"
  echo "и введите данные панели 3x-ui (адрес, логин, пароль) прямо в чате с ботом."
else
  echo "⚠️  Служба не запустилась. Смотрите: journalctl -u $SERVICE -n 50 --no-pager"
fi
echo
echo "Логи:        journalctl -u $SERVICE -f"
echo "Перезапуск:  systemctl restart $SERVICE"
exit 0
__PAYLOAD__
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
