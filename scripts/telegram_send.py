#!/usr/bin/env python3
"""Sends app builds to your own Telegram "Saved Messages" chat.

    telegram_send.py login                 one-time interactive login (run it yourself)
    telegram_send.py send FILE [CAPTION]   upload FILE to Saved Messages

Shared with TV Remote: credentials and the session live in ~/.config/tvremote-telegram
(readable only by you), never in the project folder. The session file grants full access
to the account.
"""
import asyncio
import getpass
import json
import os
import sys
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "tvremote-telegram"
CONFIG_FILE = CONFIG_DIR / "config.json"
SESSION = CONFIG_DIR / "session"  # Telethon appends ".session"
SESSION_FILE = CONFIG_DIR / "session.session"


def load_config():
    if not CONFIG_FILE.exists():
        return None
    return json.loads(CONFIG_FILE.read_text())


async def login():
    from telethon import TelegramClient

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)

    config = load_config()
    if config is None:
        print("1. Apri https://my.telegram.org, accedi e scegli 'API development tools'.")
        print("2. Crea un'app (nome e descrizione a piacere) e copia api_id e api_hash.\n")
        api_id = int(input("api_id: ").strip())
        api_hash = getpass.getpass("api_hash (non viene mostrato mentre scrivi): ").strip()
        config = {"api_id": api_id, "api_hash": api_hash}
        CONFIG_FILE.write_text(json.dumps(config))
        os.chmod(CONFIG_FILE, 0o600)

    client = TelegramClient(str(SESSION), config["api_id"], config["api_hash"])
    # Asks for phone number, login code and (if set) the two-step password in this terminal.
    await client.start()
    me = await client.get_me()
    await client.disconnect()
    os.chmod(SESSION_FILE, 0o600)
    print(f"\nAccesso effettuato come {me.first_name}. Le prossime build arriveranno in Messaggi salvati.")


async def send(path, caption):
    from telethon import TelegramClient

    config = load_config()
    if config is None or not SESSION_FILE.exists():
        print("Telegram non configurato: esegui scripts/telegram_setup.sh", file=sys.stderr)
        return 1

    client = TelegramClient(str(SESSION), config["api_id"], config["api_hash"])
    await client.connect()
    try:
        if not await client.is_user_authorized():
            print("Sessione Telegram non più valida: riesegui scripts/telegram_setup.sh", file=sys.stderr)
            return 1
        await client.send_file("me", path, caption=caption, force_document=True)
    finally:
        await client.disconnect()
    print("Build inviata a Telegram (Messaggi salvati)")
    return 0


def main():
    args = sys.argv[1:]
    if args == ["login"]:
        asyncio.run(login())
        return 0
    if len(args) in (2, 3) and args[0] == "send":
        return asyncio.run(send(args[1], args[2] if len(args) == 3 else None))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
