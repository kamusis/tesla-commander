# Tesla Commander

High-signal Tesla vehicle observability, management, and AI navigation platform. Built with a native macOS desktop client (Swift + WebKit), WebSocket Fleet Telemetry streaming, and a standalone Agent Skill / CLI.

![macOS Architecture](https://img.shields.io/badge/Platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Python](https://img.shields.io/badge/Python-3.10%2B-green)
![Tessie](https://img.shields.io/badge/Powered%20By-Tessie%20API-red)
![Vertex AI](https://img.shields.io/badge/AI%20Engine-Gemini%203.8%20Flash-purple)

---

## Key Features

### 1. Real-Time Telemetry & Live Drive Tracking
- **Live WebSocket Fleet Telemetry**: Instant battery SOC, rated range, speed, charging voltage/power, tire pressure (TPMS), and cabin/ambient temperatures.
- **Dynamic Live Route Visualizer**: Real-time breadcrumb polyline drawing on interactive Leaflet maps with dynamic vehicle heading calculation and camera follow mode (`🎯 视角跟随`).
- **Odometer Discrepancy Compensation**: Automatic detection of offline tunnel/garage driving gaps and odometer jumps, inserting synthetic compensated sessions to maintain odometer continuity.
- **Parked Location Jitter Filter**: Stabilizes parked vehicle addresses against GPS drift within 30 meters.

### 2. AI Dual-Engine Navigation & Customizable Favorites
- **AI Spatial Extraction**: Natural language destination queries in Chinese, Japanese, or English resolved into precise physical coordinates using Google Vertex AI (`gemini-3.8-flash`) with automatic fallback to OpenStreetMap Nominatim.
- **In-Car Navigation Dispatch**: Directly pushes validated coordinates to the vehicle's center MCU display (`locale=ja-JP`).
- **Customizable Favorite Destinations**: Add arbitrary favorite destinations with custom titles (Home, Office, Gym, Mall, etc.), automatic emoji categorization, and 1-click direct selection.
- **Zero Scroll Bleed**: Modal dialog locks background viewport and traps mouse wheel events to prevent background scroll chaining.

### 3. Lifetime Driving Archive & All-Time Top 20 Leaderboard
- **Offline-First Persistence**: Drive metadata stored in `~/Library/Application Support/TeslaCommander/drives_history.json` and GPS breadcrumb paths in `paths/<driveId>.json`.
- **Full History Sync Engine**: Automated batch pagination syncs entire vehicle history backwards from cloud with rate-limiting pauses and breakpoint continuation.
- **All-Time Longest Drives Top 20**: Interactive Neo-Brutalist ECharts bar chart ranking lifetime longest single drives with energy efficiency (Wh/km), average/maximum speeds, and 1-click trajectory replay.

### 4. Vehicle Control & Hardware Matrix
- **Remote Commands**: Door lock/unlock, horn, headlights flash, front trunk (frunk), rear trunk, window venting, climate preconditioning, and sentry mode toggle.
- **Charging & Hardware Matrix**: Charging limit regulation, current adjustment, and full OEM hardware build specification matrix.

---

## Repository Structure

```text
.
├── README.md
├── .gitignore
├── docs/                                  # Design specifications and ADRs
│   └── plans/
│       └── 2026-09-27-macos-native-app-design.md
├── macos/                                 # Native macOS desktop client (Swift + WebKit)
│   ├── Makefile                           # Build, run, and packaging automation
│   ├── Package.swift                      # Swift Package Manager manifest
│   ├── Sources/
│   │   ├── main.swift                     # NSApplication, window controller & menus
│   │   ├── BridgeHandler.swift            # Native WKScriptMessageHandler & telemetry dispatcher
│   │   ├── TessieClient.swift             # Async/await Tessie REST client
│   │   ├── DriveStore.swift               # Local JSON persistence & incremental sync manager
│   │   ├── LiveTripTracker.swift          # Live route breadcrumb tracking & heading calculator
│   │   └── Resources/
│   │       ├── tesla_dashboard.html       # Neo-Brutalist web dashboard & UI
│   │       ├── AppIcon.icns               # Native macOS application icon
│   │       └── Info.plist                 # Bundle metadata
└── skills/
    └── tesla-commander/
        ├── SKILL.md                       # Agent Skill instructions & interaction rules
        ├── scripts/
        │   ├── tesla_cli.py               # Main CLI entrypoint
        │   ├── tesla_client.py            # Python Tessie REST client
        │   ├── geo_resolver.py            # Dual-engine geolocator (Vertex AI + OSM)
        │   ├── env_loader.py              # Cross-shell and .env environment loader
        │   └── telemetry_stream.js        # Node.js WebSocket telemetry listener
        └── references/
            ├── api_reference.md           # Tessie REST API manual
            ├── openapi.yaml               # Official OpenAPI 3.0 specification
            └── telemetry_proto_fields.md  # Fleet Telemetry data schema
```

---

## Environment Variables

Credentials are automatically discovered from the active shell environment, local `.env` files, or user profile files (`~/.zshrc`, `~/.bashrc`, `~/.config/fish/config.fish`):

| Variable | Required | Description |
| :--- | :---: | :--- |
| `TESSIE_ACCESS_TOKEN` | **Yes** | Developer access token from [Tessie](https://tessie.com). |
| `VERTEX_API_KEY` | Optional | Google Cloud / Vertex AI API key for `gemini-3.8-flash` spatial queries. Falls back to OpenStreetMap Nominatim if missing. |
| `MY_TESLA_VIN` | Optional | Specific Tesla VIN. When omitted, auto-discovers the first active vehicle. |

---

## macOS Desktop App Quickstart

### Build and Run

```bash
cd macos

# Compile and run immediately in debug mode
make run

# Build release .app bundle
make app

# Launch application
open TeslaCommander.app
```

### Local Storage Location

All persisted data is preserved across app relaunches under:
```text
~/Library/Application Support/TeslaCommander/
├── drives_history.json      # Lifetime historical driving sessions
└── paths/                   # High-precision GPS trajectory files
    ├── 437808855.json
    └── ...
```

---

## CLI & Skill Usage

```bash
# Vehicle status summary
python3 skills/tesla-commander/scripts/tesla_cli.py status

# AI POI Navigation
python3 skills/tesla-commander/scripts/tesla_cli.py nav "Nagoya City Science Museum"
python3 skills/tesla-commander/scripts/tesla_cli.py nav "中部国際空港"

# Climate conditioning
python3 skills/tesla-commander/scripts/tesla_cli.py climate on
python3 skills/tesla-commander/scripts/tesla_cli.py climate temp 22.0

# Hardware controls
python3 skills/tesla-commander/scripts/tesla_cli.py control honk
python3 skills/tesla-commander/scripts/tesla_cli.py control lock
python3 skills/tesla-commander/scripts/tesla_cli.py control sentry_on

# WebSocket live telemetry stream
python3 skills/tesla-commander/scripts/tesla_cli.py stream --duration 30
```

---

## License

MIT License. Designed with Neo-Brutalist aesthetics, powered by Tessie and Apache ECharts.
