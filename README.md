# Loopback – Run Coach (iOS)

A privacy-first training companion for iOS that connects Apple Health data to AI coaching. Manages the full workout lifecycle — plan creation, Apple Watch scheduling, execution tracking, and performance analysis — all through a self-hosted backend you control: the [Loopback Server](https://github.com/aderaaij/loopback-training-server).

## Features

### Training Plan Management

Displays your active training plan with phase tracking, completion progress, and workout details. Plans are created by your AI coach via MCP and automatically synced to the app.

- Plan overview card with current phase, week progress, and completion rate
- Tappable phase pills showing workouts per phase
- Completed workouts show actual metrics (distance, duration, pace) alongside the plan

### Workout Scheduling & Tracking

Fetches planned workouts from your Training API and schedules them on Apple Watch via WorkoutKit:

- Structured workouts with warm-up, interval blocks, and cooldown
- Training goals (distance, time, energy, open)
- Training alerts for heart rate zones, pace, cadence, and power
- Auto-sync: new queued workouts are pulled automatically on app launch and foreground
- Queue lifecycle preserved (pending → synced → completed) for full traceability

### Workout Extraction & Upload

Pulls detailed workout data from HealthKit and sends it to your Training API:

- GPS routes with altitude, speed, and course data
- Heart rate, cadence, power, speed, stride length, vertical oscillation, and ground contact time series
- Auto-computed 1km splits with elevation gain/loss and average metrics
- Structured activity segments from WorkoutKit compositions
- Workout events (pause, resume, lap, segment, marker)
- Plan workout linking: completed workouts matched to their originating plan by time proximity
- All workout types synced (running, cycling, strength, flexibility, yoga, HIIT, 30+ types)
- Background sync via HealthKit observers — workouts upload automatically after completion

### Health Metrics Sync

Syncs daily health metrics directly from HealthKit to your Training API, giving your AI coach full context:

- Sleep duration and stages (awake, REM, core, deep)
- Resting heart rate, HRV (SDNN)
- Weight, body fat percentage, lean body mass
- VO2 Max, respiratory rate, SpO2
- Daily steps and active energy burned
- Syncs on app launch, foreground, and incrementally

### Missed Workout Detection

Detects past-due incomplete workouts and collects structured feedback:

- Reason tracking (busy, tired, weather, soreness, motivation)
- Action selection (reschedule, adjust plan, skip)
- Feedback synced to Training API for LLM pattern analysis

## Requirements

- iOS 26+
- Xcode 26+
- A self-hosted [Loopback Server](https://github.com/aderaaij/loopback-training-server) (the Training API)

## Server Setup

Loopback connects to a self-hosted [Loopback Server](https://github.com/aderaaij/loopback-training-server) (FastAPI + PostgreSQL) that stores workouts, manages training plans, syncs health metrics, and provides an MCP server for AI integration.

```bash
git clone https://github.com/aderaaij/loopback-training-server.git
cd loopback-training-server
cp .env.example .env      # set BOOTSTRAP_ADMIN_PASSWORD
docker compose up -d      # pulls a prebuilt image; migrations run automatically
```

Open the dashboard at `http://localhost:8001`, sign in as `admin`, and create an account for each athlete — the app signs in with those credentials. The full quick start, multi-user walkthrough, and exposure options are in the [server README](https://github.com/aderaaij/loopback-training-server#quick-start). The API runs on port 8001 by default; expose it over HTTPS using [Tailscale Funnel](https://tailscale.com/kb/1223/funnel/) or a reverse proxy like Caddy/nginx.

### Key Endpoints

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/workouts` | Accepts extracted workout JSON (upserts by workout ID) |
| `GET` | `/api/workouts/queue` | Returns pending workout compositions for Apple Watch |
| `PATCH` | `/api/workouts/queue/{id}` | Updates queue item status (synced, completed) |
| `PUT` | `/api/workouts/inventory` | Syncs device workout inventory (completion status) |
| `POST` | `/api/health/metrics` | Bulk upsert daily health metrics |
| `GET` | `/api/plans?status=active` | Returns active training plan with phases and goals |
| `GET` | `/api/plans/{id}/workouts` | Returns all workouts for a plan |
| `POST` | `/api/workouts/feedback` | Records missed workout feedback |

All endpoints require a per-user bearer token, which the app mints via `POST /api/auth/login` when you sign in (tokens can also be created in the server dashboard under **Settings → Create token**).

### MCP Integration

The Training API includes an MCP server at `/mcp` that lets AI assistants (like Claude) create training plans, queue workouts, query performance data, read health metrics, and analyze missed workout patterns. See the [Loopback Server repository](https://github.com/aderaaij/loopback-training-server) for setup instructions.

## App Setup

### 1. Clone the repository

```bash
git clone https://github.com/aderaaij/loopback-training-app.git
cd loopback-training-app
```

### 2. (Optional) Pre-fill dev credentials

You can normally skip this: on first launch the app shows a login screen where you enter the server URL, username, and password, and it mints its own per-device token. For development builds you can pre-seed the server URL (and optionally a pre-minted token) instead:

```bash
cp Secrets.example.xcconfig Secrets.xcconfig
```

Edit `Secrets.xcconfig`:

```
WORKOUT_API_BASE_URL = https://your-server.example.com:8443
WORKOUT_API_KEY = optional-pre-minted-token
```

> `Secrets.xcconfig` is git-ignored and will never be committed. Its values flow through Info.plist and seed the app once; signing in from the login screen overrides them.

### 3. Open in Xcode

```bash
open OpenHealthSync.xcodeproj
```

If you created `Secrets.xcconfig` in step 2, set it as the base configuration:

1. Select the **OpenHealthSync** project in the navigator
2. Go to **Info** → **Configurations**
3. Under both **Debug** and **Release**, set the **OpenHealthSync target** row to `Secrets`

### 4. Run

Build and run on a physical device. On first launch, sign in with your server URL, username, and password (accounts are created by the admin in the server dashboard); pasting a pre-minted token works as an advanced alternative. The app will request HealthKit permissions for workout and health metric access.

> HealthKit is available in the simulator but has no data. For full testing, use a physical device with an Apple Watch.

## Architecture

| Component | Role |
|---|---|
| `WorkoutScheduleManager` | Fetches planned workouts from the API, schedules on Apple Watch, manages queue lifecycle and plan data |
| `WorkoutManager` | Fetches workouts from HealthKit, deduplicates, coordinates extraction/upload, matches plans to completed workouts |
| `WorkoutExtractor` | Actor that concurrently extracts routes, time series, splits, activities, and events |
| `WorkoutAPIClient` | Actor-based HTTP client for all Training API endpoints |
| `HealthMetricsSyncer` | Actor that queries HealthKit for daily health metrics and syncs to Training API |
| `BackgroundSyncManager` | Registers HealthKit background delivery observers for automatic workout and metrics sync |
| `MissedWorkoutDetector` | Detects past-due incomplete workouts and manages feedback collection |

### Key Patterns

- `@MainActor` isolation for all UI-bound state managers
- Swift actors for thread-safe async operations (`WorkoutExtractor`, `WorkoutAPIClient`, `HealthMetricsSyncer`)
- `async/await` throughout
- `@AppStorage` for config persistence
- HealthKit background delivery for automatic sync
- Auto-sync on launch and foreground with manual refresh fallback

## License

TBD
