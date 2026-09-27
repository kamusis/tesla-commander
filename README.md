# Tesla Commander (Tessie & Telemetry Skill Repository)

High-signal Agent Skill and CLI tool for Tesla vehicle management, live WebSocket Fleet Telemetry streaming, and AI-powered in-car navigation.

## Repository Structure

Following standard Agent Skill directory specifications:

```text
.
├── README.md
├── .gitignore
├── docs/                            # Design specs & architecture plans
│   └── plans/
│       └── 2026-09-27-macos-native-app-design.md
├── macos/                           # Standalone native Swift macOS application (WebKit + WebSocket)
│   ├── Package.swift
│   ├── Makefile
│   └── Sources/
└── skills/
    └── tesla-commander/
        ├── SKILL.md                 # Agent Skill instructions & interaction rules
        ├── scripts/
        │   ├── tesla_cli.py         # Main CLI entrypoint
        │   ├── tesla_client.py      # Tessie REST API client & VIN resolver
        │   ├── geo_resolver.py      # Dual-engine (Vertex AI + OSM) geolocator
        │   ├── env_loader.py        # Universal cross-shell & .env loader
        │   └── telemetry_stream.js  # Node.js WebSocket telemetry streamer
        └── references/
            ├── api_reference.md     # Full Tessie REST API endpoint manual
            ├── openapi.yaml         # Official OpenAPI 3.0 specification
            └── telemetry_proto_fields.md # Fleet Telemetry data schema
```

## Quick Start

```bash
# View vehicle status
python3 skills/tesla-commander/scripts/tesla_cli.py status

# AI Navigation to POI
python3 skills/tesla-commander/scripts/tesla_cli.py nav "Nagoya City Science Museum"

# Turn on climate and set temp
python3 skills/tesla-commander/scripts/tesla_cli.py climate on
python3 skills/tesla-commander/scripts/tesla_cli.py climate temp 22.0

# Stream live telemetry
python3 skills/tesla-commander/scripts/tesla_cli.py stream --duration 15
```

## Environment Variables

The CLI and macOS App automatically read from the active environment, a local `.env` file, or shell configuration files (`~/.zshrc`, `~/.bashrc`, `~/.config/fish/config.fish`):
- `TESSIE_ACCESS_TOKEN` (Required): Tessie API Token.
- `VERTEX_API_KEY` (Optional): Google Vertex AI API Key for `gemini-3.8-flash`. (Falls back to OpenStreetMap if absent).
- `MY_TESLA_VIN` (Optional): Default VIN to bypass automatic vehicle resolution.

## macOS Native App (v2.0 Native Streaming Architecture)

A standalone, zero-external-dependency Swift macOS application located in `macos/`.

```bash
cd macos

# Run directly
swift run
# Or via Makefile
make run

# Build standalone .app bundle
make app
# Run the app bundle
open TeslaCommander.app
```
