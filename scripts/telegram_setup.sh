#!/bin/sh
# One-time setup so that ./build.sh (here and in TV Remote) sends each new build to your Telegram "Saved Messages".
# Run it yourself in Terminal: it asks for your api_id/api_hash, phone number and login code.
set -e

DIR="$HOME/.config/tvremote-telegram"
mkdir -p "$DIR"
chmod 700 "$DIR"

if [ ! -x "$DIR/venv/bin/python" ]; then
    echo "Installing Telethon (Telegram library) in $DIR/venv…"
    python3 -m venv "$DIR/venv"
    "$DIR/venv/bin/pip" install --quiet --disable-pip-version-check telethon
fi

"$DIR/venv/bin/python" -I "$(dirname "$0")/telegram_send.py" login
