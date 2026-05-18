"""Outbound Telegram notifications for Archer.

Routes through Velocity's send_message() when available.
Falls back to direct Telegram Bot API using ARCHER_TELEGRAM_BOT_TOKEN.
"""
from __future__ import annotations

import logging
import os
import subprocess

from src.config import settings

logger = logging.getLogger("archer.telegram")

ARCHER_PREFIX = "*@archer:* "


def send(text: str) -> bool:
    """Send a Telegram message prefixed with *@archer:*."""
    prefixed = f"{ARCHER_PREFIX}{text}"

    # Try Velocity first
    if settings.velocity_dir.exists():
        try:
            result = subprocess.run(
                [
                    str(settings.velocity_dir / ".venv/bin/python"),
                    "-c",
                    "import os,sys; sys.path.insert(0,'.');"
                    " from cos.integrations.telegram_bot import send_message;"
                    " send_message(os.environ['ARCHER_MSG'])",
                ],
                env={**os.environ, "ARCHER_MSG": prefixed},
                cwd=str(settings.velocity_dir),
                capture_output=True,
                timeout=30,
            )
            if result.returncode == 0:
                return True
            logger.warning("Velocity send failed (rc=%d), trying direct", result.returncode)
        except Exception as exc:
            logger.warning("Velocity send error: %s, trying direct", exc)

    # Fallback: direct Telegram API
    if not settings.archer_telegram_bot_token or not settings.archer_telegram_chat_id:
        logger.debug("No Telegram credentials configured — notification skipped")
        return False

    try:
        import httpx

        resp = httpx.post(
            f"https://api.telegram.org/bot{settings.archer_telegram_bot_token}/sendMessage",
            json={
                "chat_id": settings.archer_telegram_chat_id,
                "text": prefixed,
                "parse_mode": "Markdown",
            },
            timeout=10,
        )
        return resp.status_code == 200
    except Exception as exc:
        logger.warning("Direct Telegram send failed: %s", exc)
        return False
