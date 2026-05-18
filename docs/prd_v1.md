# Archer — Autonomous Repo Maintenance Agent
## PRD v1.0 · 2026-05-17

---

## Problem

Autonomous code maintenance across repos today requires:
- Four hand-rolled bash scripts with hardcoded KRI-IP assumptions
- Manual Codex review sessions triggered by JB for every `[codex review]` issue
- No memory of what worked or failed in previous runs
- No way to interact with or redirect a run in progress
- Zero visibility into run history or per-issue outcomes
- Config changes require editing bash scripts and re-running `install-crew.sh`

The bash scripts solved an immediate need but hit their ceiling: they can't be pointed at a second repo, can't be reasoned with, and can't learn.

---

## What Archer Is

Archer is a standalone autonomous agent system that monitors GitHub repos, plans and executes nightly build batches, performs automated code review, and communicates with JB via Telegram. It is fully configurable per repo via YAML, runs as a persistent process, and maintains a memory of build history and per-repo patterns.

Archer is **not** part of KRI-IP or Velocity. It is its own repo and process.

---

## Goals

| # | Goal |
|---|------|
| G1 | Replace the 4 KRI-IP bash scripts with no loss of function |
| G2 | Replace the manual Codex review workflow with an automated, schedulable command |
| G3 | Support any GitHub repo with zero code changes — config only |
| G4 | Enable bidirectional Telegram: JB can query status, cancel runs, reshape plans |
| G5 | Maintain persistent memory of build history and per-repo patterns |
| G6 | Provide an admin UI: run history, issue outcomes, PR links, config editor |

---

## Non-Goals (v1)

- Auto-merging PRs (JB issues merge commands)
- Deploying to production
- Multi-user support
- Cloud hosting (runs locally on JB's Mac)

---

## Architecture

### Repo Structure

```
archer/
├── src/
│   ├── app.py                # FastAPI app factory
│   ├── config.py             # Pydantic settings (.env)
│   ├── core/
│   │   ├── db.py             # SQLAlchemy async + Alembic
│   │   ├── scheduler.py      # APScheduler — all jobs registered here
│   │   └── telegram.py       # Bot: inbound webhook + outbound via Velocity
│   ├── models/               # archer_* ORM tables
│   ├── engine/
│   │   ├── runner.py         # claude -p headless invocations + timeout
│   │   ├── github.py         # gh CLI wrapper (issues, PRs, labels, comments)
│   │   └── chain.py          # Agent chain executor (configurable per repo)
│   ├── jobs/
│   │   ├── morning_sweep.py  # Automated review + fix of flagged issues
│   │   ├── evening_plan.py   # Reads backlog, produces overnight plan, asks JB
│   │   ├── overnight_build.py# Executes plan, pushes branches, opens PRs
│   │   └── morning_summary.py# Digest of last night's results
│   ├── api/
│   │   └── routes/           # Admin UI routes
│   └── templates/            # Jinja2 + HTMX admin UI
├── config/
│   └── repos.yaml            # All repo configurations
├── alembic/
├── .env                      # Secrets (not committed)
├── CLAUDE.md
└── requirements.txt
```

### Tech Stack

Python 3.12 | FastAPI + Jinja2 + HTMX | SQLite (dev) / PostgreSQL (prod) | SQLAlchemy 2.0 async + Alembic | APScheduler | `claude` CLI + `gh` CLI

---

## Configuration

Every aspect of Archer's behavior is driven by `config/repos.yaml`. No code changes needed to add a repo.

```yaml
repos:
  kri-ip:
    slug: velo9-ai/KRI-IP
    local_path: ~/Developer/velo9-dev/kri-ip
    base_branch: main

    # Which issues to pick up
    issue_filters:
      labels: [overnight/ready-bug, overnight/ready-feature]
      title_patterns: ["[codex review]"]
      exclude_labels: [overnight/blocked, wontfix]

    # Agent chain per job type. Each entry is a named agent Archer
    # invokes in sequence via claude -p. Archer passes results between
    # agents using a shared context file per issue.
    agent_chains:
      sweep:    [pam, archie, tom, bob, tina, tom, cody]
      build:    [pam, archie, tom, bob, tina, tom, cody]
      review:   [tina, tom, cody]   # lightweight — for Codex-style checks

    schedules:
      morning_sweep:
        time: "06:30"
        days: [Mon, Tue, Wed, Thu, Fri]
      evening_plan:
        time: "18:00"
        days: [Sun, Mon, Tue, Wed, Thu]
      overnight_build:
        time: "23:30"
        days: [Mon, Tue, Wed, Thu, Fri]
      morning_summary:
        time: "07:00"
        days: [Mon, Tue, Wed, Thu, Fri]

    limits:
      max_issues_per_run: 5
      issue_timeout_secs: 5400   # 90 min hard limit per issue
      concurrent_issues: 1       # sequential by default

    notifications:
      provider: velocity   # velocity | telegram_direct
      # velocity: calls cos.integrations.telegram_bot.send_message()
      #           from ~/Developer/velo9-dev/velocity
      # telegram_direct: posts via Bot API with own token

    # Optional: on-demand review trigger (replaces manual Codex session)
    review:
      enabled: true
      # archer review --repo kri-ip --issue 352
      # or triggered by labeling an issue "archer/review-requested"
      trigger_label: archer/review-requested
      post_result_as_comment: true
```

---

## Database Schema

### `archer_repos`
| Column | Type | Notes |
|--------|------|-------|
| id | uuid | |
| slug | text | `velo9-ai/KRI-IP` |
| display_name | text | |
| config_snapshot | jsonb | YAML config at last load |
| enabled | bool | |
| created_at | timestamptz | |

### `archer_runs`
| Column | Type | Notes |
|--------|------|-------|
| id | uuid | |
| repo_id | uuid → archer_repos | |
| job_type | text | `morning_sweep`, `evening_plan`, `overnight_build`, `morning_summary`, `review` |
| status | text | `scheduled`, `running`, `completed`, `cancelled`, `failed` |
| plan | jsonb | evening plan JSON (issue list + questions + defaults) |
| result_summary | jsonb | counts: built, blocked, failed, skipped |
| started_at | timestamptz | |
| completed_at | timestamptz | |
| triggered_by | text | `scheduler`, `telegram`, `api` |

### `archer_issue_results`
| Column | Type | Notes |
|--------|------|-------|
| id | uuid | |
| run_id | uuid → archer_runs | |
| repo_id | uuid → archer_repos | |
| issue_number | int | |
| issue_title | text | |
| status | text | `built`, `blocked`, `failed`, `skipped`, `timeout` |
| branch | text | |
| pr_url | text | nullable |
| agent_chain_log | text | full stdout from claude -p |
| cody_verdict | text | `PASS`, `FAIL`, `CONCERNS` |
| duration_secs | int | |
| created_at | timestamptz | |

### `archer_memory`
| Column | Type | Notes |
|--------|------|-------|
| id | uuid | |
| repo_id | uuid → archer_repos | |
| memory_type | text | `issue_pattern`, `build_outcome`, `jb_preference`, `repo_context` |
| key | text | e.g. `label:overnight/ready-bug` |
| content | text | learned context injected into future planning prompts |
| confidence | float | decays over time if contradicted |
| last_updated | timestamptz | |

### `archer_chat_messages`
| Column | Type | Notes |
|--------|------|-------|
| id | uuid | |
| direction | text | `inbound`, `outbound` |
| text | text | |
| context | jsonb | active run, repo, intent parsed |
| created_at | timestamptz | |

---

## Jobs

### Morning Sweep (6:30am weekdays)

Picks up issues with `[codex review]` title or `overnight/ready-bug` label. For each issue: runs the configured `sweep` agent chain via `claude -p`, pushes a branch, opens a PR. Cody FAIL → label `overnight/blocked` + comment, skip PR.

Identical behavior to current `kri-codex-sweeper.sh` but repo-agnostic and recorded in DB.

### Evening Plan (6:00pm Sun–Thu)

Reads all open issues for each configured repo. Runs a Claude planning session that:
1. Clusters issues by complexity/risk
2. Recommends tonight's build batch (respects `max_issues_per_run`)
3. Identifies PRD questions only JB can answer
4. Saves plan to `archer_runs` (status: `planned`)
5. Sends plan + questions to Telegram as `*@archer:*`

JB can reply via Telegram to reshape the plan before 11:30pm.

### Overnight Build (11:30pm Mon–Fri)

Reads the evening plan from DB. For each issue: cuts branch, runs `build` agent chain, pushes, opens PR. Records each outcome in `archer_issue_results`. Never merges, never deploys.

If no plan exists (evening job failed/skipped): falls back to GH label query directly.

Cancel mechanism: JB texts "cancel tonight" or "skip kri-ip" → Archer sets run status to `cancelled` before the 11:30pm fire.

### Morning Summary (7:00am Mon–Fri)

Reads last night's `archer_runs` results from DB. Sends digest to Telegram:
- N PRs opened (links)
- M issues blocked (reasons)
- K issues failed or timed out

### On-Demand Review (replaces manual Codex sessions)

Triggered by:
- CLI: `archer review --repo kri-ip --issue 352`
- GitHub label: `archer/review-requested` on any issue
- Telegram: "review issue 352 on kri-ip"

Runs the `review` agent chain, posts result as a GitHub issue comment, sends Telegram summary.

---

## Bidirectional Telegram

Archer registers a webhook (or uses polling) on its own Telegram bot. Recognized intents:

| Message | Action |
|---------|--------|
| "what's building?" / "status" | Current run status for all repos |
| "cancel tonight" | Cancels overnight build for all repos |
| "cancel kri-ip tonight" | Cancels overnight build for one repo |
| "skip issue 352" | Removes issue 352 from tonight's plan |
| "show me the plan" | Prints tonight's planned issue list |
| "add issue 355 to tonight" | Adds issue to plan |
| "review issue 352 on kri-ip" | Triggers on-demand review |
| "what did you build last night?" | Yesterday's results |
| "what's blocked?" | Open `overnight/blocked` issues |

Unknown messages → passed to a Claude context window with archer's current state for free-form response.

---

## Memory System

After each run, Archer extracts learnings and stores them in `archer_memory`:

- **Issue patterns**: "Issues touching `src/pipeline/stages/` on KRI-IP tend to need Archie review" → injected into future planning prompts for that repo
- **Build outcomes**: "Issue #312 (same event_type bucket) took 87min and failed Cody — similar issues flagged for JB review"
- **JB preferences**: Extracted from Telegram replies ("always include PDUFA issues even if low score") → stored as `jb_preference` and injected into evening plan prompts

Memory is surfaced in the admin UI and can be edited/deleted by JB.

---

## Admin UI

| Route | Page |
|-------|------|
| `/` | Dashboard: all repos, next scheduled runs, active run status |
| `/repos` | Repo list + quick enable/disable |
| `/repos/:slug` | Repo detail: config viewer, last 30 runs |
| `/repos/:slug/config` | YAML config editor (inline, saves to `repos.yaml`) |
| `/repos/:slug/memory` | Memory entries for this repo — view + delete |
| `/runs` | All runs across all repos, paginated |
| `/runs/:id` | Run detail: plan, per-issue outcomes, agent chain logs, PR links |
| `/chat` | Telegram conversation history |

---

## Notification Flow

Archer routes outbound Telegram messages through Velocity when available:

```python
# archer/src/core/telegram.py
def send(text: str) -> bool:
    prefixed = f"*@archer:* {text}"
    velocity_dir = Path.home() / "Developer/velo9-dev/velocity"
    if velocity_dir.exists():
        # Delegate to Velocity's send_message() — uses Velocity's bot/token/chat_id
        result = subprocess.run(
            [str(velocity_dir / ".venv/bin/python"), "-c",
             "import os,sys; sys.path.insert(0,'.'); "
             "from cos.integrations.telegram_bot import send_message; "
             "send_message(os.environ['ARCHER_MSG'])"],
            env={**os.environ, "ARCHER_MSG": prefixed},
            cwd=str(velocity_dir),
            capture_output=True, timeout=30,
        )
        return result.returncode == 0
    # Fallback: direct Telegram API with own bot token
    ...
```

---

## Phase Plan

### Phase 1 — Core Engine + KRI-IP Migration
- `archer/` repo scaffold (FastAPI, SQLAlchemy, Alembic, APScheduler)
- `repos.yaml` config loader with Pydantic validation
- DB schema + migrations
- `engine/runner.py` — `claude -p` invocation with timeout, lock, logging
- `engine/github.py` — issue fetch, label ops, PR creation
- `engine/chain.py` — sequential agent chain executor
- All 4 jobs (morning_sweep, evening_plan, overnight_build, morning_summary)
- Notification via Velocity
- KRI-IP configured as first repo; all 4 launchd scripts replaced
- **Exit criteria**: Archer runs a full week of KRI-IP automation at feature parity with the bash scripts

### Phase 2 — Bidirectional Telegram
- Archer Telegram bot (webhook or polling)
- Intent parser for recognized commands
- Free-form fallback via Claude
- Cancel/skip/plan-reshape commands wired to DB

### Phase 3 — Memory + Learning
- Post-run memory extraction
- Memory injection into evening plan prompts
- Admin UI: memory viewer/editor

### Phase 4 — Admin UI
- Full dashboard (all routes listed above)
- Config editor
- Run detail with agent chain logs

### Phase 5 — On-Demand Review (Codex replacement)
- `archer review` CLI command
- `archer/review-requested` label trigger
- Telegram-triggered review
- GitHub comment posting

---

## Migration Plan (KRI-IP)

Once Phase 1 is complete and validated for one week:
1. Remove `scripts/automation/kri-codex-sweeper.sh`, `kri-evening-qa.sh`, `kri-overnight-build.sh`, `kri-morning-summary.sh`
2. Remove `scripts/automation/install-crew.sh` and all plists
3. Archer's launchd agent (a single persistent process keeper) replaces the 4 individual agents

---

## Open Questions

1. **Telegram bot**: Does Archer get its own dedicated bot, or does it piggyback on the Velocity bot (same token, different prefix)? Dedicated bot preferred for clean separation.
2. **DB**: SQLite for v1 (simpler local ops) or Postgres from day one (matches KRI/Velocity ops muscle memory)?
3. **`claude -p` vs Agent SDK**: Use the CLI for now (consistent with current approach) or wire up to Anthropic Agent SDK for richer observability?
