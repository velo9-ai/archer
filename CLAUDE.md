# Archer — Autonomous Repo Maintenance Agent

> Standalone system. Monitors GitHub repos, plans and executes nightly build batches,
> performs automated code review, communicates with JB via Telegram.

## Documentation

- **CLAUDE.md** (this file) — runtime constraints, session-critical facts
- **docs/prd_v1.md** — full PRD: goals, architecture, DB schema, phase plan
- **BUILD.md** — subsystem internals (written as system is built)
- **legacy/** — the KRI-IP bash scripts Archer replaces (reference only)

## Tech Stack

Python 3.12 | FastAPI + Jinja2 + HTMX | PostgreSQL + SQLAlchemy 2.0 async + Alembic | APScheduler | `claude` CLI + `gh` CLI

## Project Structure

```
src/
├── app.py              # FastAPI app factory
├── config.py           # Pydantic settings (.env)
├── core/
│   ├── db.py           # SQLAlchemy async session + engine
│   ├── scheduler.py    # APScheduler — all jobs registered here
│   └── telegram.py     # Outbound: via Velocity. Inbound: polling loop.
├── models/             # archer_* ORM tables
├── engine/
│   ├── runner.py       # claude -p headless invocations + timeout + lock
│   ├── github.py       # gh CLI wrapper (issues, PRs, labels, comments)
│   └── chain.py        # Agent chain executor — reads/writes context.json per issue
├── jobs/
│   ├── morning_sweep.py
│   ├── evening_plan.py
│   ├── overnight_build.py
│   └── morning_summary.py
├── api/routes/         # Admin UI routes
└── templates/          # Jinja2 + HTMX
config/
└── repos.yaml          # All repo configurations (version-controlled)
```

## Hard Constraints

1. **Never merge PRs** — Archer opens PRs; JB issues merge commands.
2. **Never deploy** — Archer does not touch production of any repo.
3. **Notifications via Velocity** — Call `cos.integrations.telegram_bot.send_message()` from Velocity's venv. Fall back to direct Telegram API if Velocity not present.
4. **All `claude -p` invocations** — headless, `--dangerously-skip-permissions`, `--output-format text`, per-issue timeout enforced via `gtimeout`/`timeout`.
5. **Config in `repos.yaml`** — no repo-specific logic in Python code.
6. **Never `git add -A`** — `.env`, credentials must never be committed.
7. **Secrets in `.env`** — never hardcoded.
8. **Issue state machine in DB** — never derive state from filesystem; always from `archer_issue_results.status`.
9. **Context file per issue** — agent chain steps communicate via a JSON context file managed by `chain.py`. No state in environment variables.
10. **No main branch edits** — all changes via topic branch (`fix/*`, `feature/*`, `chore/*`, `docs/*`).

## Key Models (once built)

| Model | Table | Notes |
|-------|-------|-------|
| `Repo` | `archer_repos` | Registered repos + config snapshot |
| `Run` | `archer_runs` | Scheduled run instance + plan JSON + result summary |
| `IssueResult` | `archer_issue_results` | Per-issue outcome, branch, PR, Cody verdict |
| `Memory` | `archer_memory` | Learned patterns per repo |
| `ChatMessage` | `archer_chat_messages` | Telegram conversation history |

## Local Dev

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn src.app:app --reload      # Admin UI at localhost:8100
```

## Notification Pattern

```python
# All outbound Telegram in src/core/telegram.py
from archer.core.telegram import send  # send("your message")
# Prefixes with *@archer:* and delegates to Velocity's send_message()
```

## Open Questions (answer before building)

1. Does Archer get its own Telegram bot, or share Velocity's bot with `*@archer:*` prefix?
2. Archer's own Postgres DB, or new schema in KRI-IP's existing Postgres?
3. Repo location — `velo9-ai/archer`?
