# Bio-Inspired Drone Swarm Simulator

## Description

This project is a software prototype built for a research paper on
bio-inspired engineering. It simulates a drone swarm whose damage-response
and rescue behavior is modeled on the battlefield triage behavior of the
Matabele ant (*Megaponera analis*), documented by Frank et al. (2018):
injured ants that signal moderate damage are carried home and treated by
nest-mates, while catastrophically injured ants are left behind.

The swarm is organized into three castes, mirroring that division of labor:

- **Alpha** — command/allocation role. Assigns incoming mission objectives
  to healthy Worker drones using a priority-queue (heap) allocator.
- **Worker** — carries out missions. Can be damaged over the course of a
  run and progresses through a four-tier damage state machine.
- **Beta** — rescue/triage role. Detects a Worker's distress signal,
  navigates to it (A* pathfinding + KD-tree spatial search), and escorts it
  to a safe zone for repair.

**Damage state machine (four tiers):**

| Tier | Name | Behavior |
|---|---|---|
| L1 | MINOR | Voltage compensation — self-corrects, no external help needed |
| L2 | MODERATE | Surveillance pivot — role changes, keeps operating |
| L3 | SEVERE | SOS broadcast — a Beta drone intercepts and transports it to safety |
| L4 | CATASTROPHIC | Termination — unit is lost |

The central research question is whether this triage layer measurably
improves swarm outcomes. The prototype therefore supports two run modes:

- **Experimental** — the full triage behavior described above.
- **Control** — identical L1/L2 behavior, but L3-damaged drones receive
  **no rescue** and bleed out to termination on their own. This is the
  baseline the experimental arm is compared against.

The prototype has three parts:

- **Backend** (`swarm_backend/`) — Python 3.13 + FastAPI. Runs the
  simulation tick loop, streams live state over WebSocket/SSE, and
  persists every run to MySQL for later analysis.
- **Frontend** (`swarm_frontend/`) — Next.js + React Three Fiber. A live
  3D dashboard of the swarm in motion, plus a results page listing past
  persisted runs with their metrics.
- **Database** (`swarm_backend/database/`) — MySQL schema and SQL views
  that compute the paper's actual results: mission completion rate,
  asset survivability rate, mean time between failures (MTBF), and mean
  time-to-repair.

---

## Changes made

The original prototype had a working live simulation (agent models, damage
FSM, mission allocator, rescue navigation, WebSocket dashboard) but no way
to generate the statistical, repeatable results a paper needs. The
following was added on top of that:

### 1. Database persistence (`swarm/persistence/`)

- `db.py` — SQLAlchemy mapping of the existing MySQL schema
  (`simulation_runs`, `drone_registry`, `mission_tasks`, `telemetry_logs`);
  also usable with SQLite for local testing.
- `recorder.py` — an async, non-blocking writer. All DB writes run on a
  background thread fed by a queue, so persistence never slows down the
  live simulation tick loop. Records:
  - one `simulation_runs` row per run (mode, scenario config, seed),
  - one `drone_registry` row per drone (initial state, caste),
  - one `mission_tasks` row per loaded objective, updated on
    assignment/completion/abort (with `abort_count` tracking re-queues),
  - batched `telemetry_logs` rows (position, velocity, health, damage
    tier, state) at a configurable interval,
  - termination timestamps and final states on run end.

### 2. Control vs. Experimental mode switch

- `SwarmEngine` now accepts `mode: "control" | "experimental"`.
- In control mode, the rescue engine's dispatch logic
  (`swarm/navigation/rescue.py`) is disabled via a `dispatch_enabled` flag —
  L3-damaged drones are never intercepted and terminate on their own.
- L1/L2 behavior is identical in both modes; only the triage/rescue layer
  is the independent variable, so the comparison isolates exactly the
  thing the paper is testing.
- Exposed via `POST /api/simulation/start`, with mode recorded in
  `simulation_runs.scenario`.

### 3. Headless batch runner (`scripts/run_batch.py`)

- Runs N independent trials per mode with no WebSocket/real-time loop
  (calls `engine.tick()` in a tight loop), so a full experiment finishes
  in seconds rather than wall-clock simulation time.
- Poisson-process damage injection at a configurable rate, with seeded
  reproducibility (`seed + trial_index`) so control/experimental pairs
  start from matched random conditions.
- Persists every trial through the same recorder as the live service
  (or skips persistence entirely with `--no-db`).
- Prints a summary table (mean ± standard deviation across trials) for
  completion rate, survivability rate, MTBF, and time-to-repair — ready to
  paste into the paper's results section.

### 4. Results API and export

- `GET /api/runs` — lists all persisted runs, newest first.
- `GET /api/runs/{run_id}/metrics` — returns the `v_run_metrics` SQL view
  as JSON (completion %, survivability %, MTBF, time-to-repair).
- `GET /api/runs/{run_id}/export.csv` — streams the full `telemetry_logs`
  table for one run, for offline plotting.
- `swarm_frontend/app/runs/page.jsx` — a simple results table in the
  dashboard pulling from the above endpoints, with a CSV download button.

### Tests added (`swarm_backend/tests/`)

- `test_persistence.py` — round-trips a run through the recorder against
  an in-memory SQLite database and checks every table is written
  correctly (runs, drones, missions, telemetry, abort counts, final
  states).
- `test_control_mode.py` — proves control mode never dispatches a rescue
  and the damaged drone terminates, proves experimental mode rescues it,
  and proves L1/L2 behavior is identical in both modes.

---

## How to run it

### Fastest path: automated setup script

Two scripts are included that do all of the below in one step —
`setup_and_run.bat` (Windows) or `setup_and_run.sh` (macOS/Linux). Place
either one next to your unzipped project folder, edit the `DB_*` variables
near the top to match your MySQL setup, and run it. It will check
prerequisites, create a virtual environment, install dependencies,
optionally apply the database schema, run the test suite, and launch both
the backend and frontend.

### Manual setup

**1. Database (MySQL 8+)** — only needed once, on a fresh database:

```bash
cd swarm_backend
mysql -u root -p < database/01_schema.sql
mysql -u root -p < database/02_views.sql
```

> `01_schema.sql` starts with `DROP TABLE` statements — don't rerun it on a
> database that already holds results you want to keep.

Set connection details as environment variables (or copy `.env.example`
to `.env`):

| Variable | Default | Notes |
|---|---|---|
| `DB_HOST` | *(unset)* | Set this to enable persistence |
| `DB_PORT` | `3306` | |
| `DB_USER` | `root` | |
| `DB_PASSWORD` | `""` | |
| `DB_NAME` | `swarm_db` | |
| `DATABASE_URL` | *(unset)* | Full SQLAlchemy URL, overrides the above (e.g. `sqlite:///local.db`) |

If no database is configured, the live simulation still runs normally;
persistence is simply skipped and `/api/runs*` returns HTTP 503.

**2. Backend:**

```bash
cd swarm_backend
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate.bat
pip install -r requirements.txt
uvicorn api.server:app --reload --port 8000
```

**3. Frontend** (in a second terminal):

```bash
cd swarm_frontend
npm install
npm run dev
```

- Live dashboard: http://localhost:3000
- Persisted-run results table: http://localhost:3000/runs

**4. Tests** (no database required — uses an in-memory SQLite mirror):

```bash
cd swarm_backend
python -m pytest -q
```

**5. Batch experiment runner** (generates the paper's actual comparison
data):

```bash
cd swarm_backend
python scripts/run_batch.py --mode both --trials 20 --duration 600 \
    --damage-rate 0.05
```

Useful options: `--mode control|experimental|both`, `--trials`,
`--duration`, `--damage-rate`, `--seed`, `--db-url`, `--no-db`,
`--require-db`. Run `python scripts/run_batch.py --help` for the full list.

---

## Project structure

```
swarm_backend/
  swarm/                 engine, damage FSM, mission queue, rescue, models
  swarm/persistence/     db.py (schema mapping) + recorder.py (async writer)
  swarm/factory.py       scenario / drone-count builder
  swarm/damage.py        tier-advance helper + Poisson damage scheduler
  swarm/metrics.py       per-trial metrics + aggregation
  api/                   FastAPI service, schemas, routes
  database/              01_schema.sql, 02_views.sql (MySQL)
  scripts/run_batch.py   headless experiment runner
  tests/                 persistence + control-mode tests (SQLite)
swarm_frontend/
  app/page.jsx           live dashboard
  app/runs/page.jsx      persisted-run results table
setup_and_run.bat        one-step setup/run script (Windows)
setup_and_run.sh         one-step setup/run script (macOS/Linux)
```
