# Win Stat Server

A lightweight Windows dashboard for inspecting live HWiNFO telemetry and completed CapFrameX captures in a web browser. Win Stat Server reads HWiNFO shared memory directly and proxies CapFrameX's local MCP endpoint without requiring a separate monitoring service.

The current release is **v8.0.0**.

## Features

- Live readings for every sensor exposed through HWiNFO shared memory
- Gaming, GPU, CPU, and memory overview panels
- Pinned telemetry cards with session statistics and interactive graphs
- Non-destructive laps with current-lap, historical-lap, and full-session views
- FPS and frame-time analysis based on HWiNFO source updates
- Configurable target FPS, health indicators, themes, and typography
- Portable dashboard configuration through JSON export/import
- Wide analysis CSV export and structured AI analysis JSON
- Mapping diagnostics that reject ambiguous or semantically incorrect sensors
- Optional CapFrameX integration with true per-frame frametimes, FPS metrics, stutter and freeze detection
- Dedicated Capture Analyzer with selectable ranges and synchronized HWiNFO sensor graphs
- Bounded server-side HWiNFO history for capture correlation
- One-click KUM-FPS bootstrap for the complete local toolchain
- Local IPv4 and IPv6 access with non-loopback requests rejected

## Requirements

- Windows
- HWiNFO64 running in Sensors-only mode
- **Shared Memory Support** enabled in HWiNFO settings
- PowerShell with permission to run the included script
- A modern web browser

CapFrameX is optional for the live HWiNFO dashboard. The Capture Analyzer requires a current CapFrameX release with its local MCP endpoint enabled.

## Quick start

1. Start HWiNFO64 in Sensors-only mode.
2. Enable **Settings → Shared Memory Support**.
3. Run `START-PERFORMANCE-LAB.bat`.
4. Open <http://localhost:8080>.

You can also start the server directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\hwinfo-performance-lab.ps1
```

To use another port:

```powershell
powershell -ExecutionPolicy Bypass -File .\hwinfo-performance-lab.ps1 -Port 8081
```

The live sensor endpoint is available at `http://127.0.0.1:8080/api/sensors`.

When CapFrameX is running, open <http://localhost:8080/dash> for the Capture Analyzer.

## Complete KUM-FPS setup

For a complete installation, run:

```bat
INSTALL-KUM-FPS.bat
```

The bootstrap reuses or installs HWiNFO, installs the latest stable portable CapFrameX and its required runtimes, downloads Tunnelmole, optionally installs Parsec, and creates local and remote desktop launchers. It does not start the stack or create a public tunnel automatically.

See [README-bootstrap.md](README-bootstrap.md) for installed locations, flags, logging, and operational notes.

## CapFrameX integration

Win Stat Server discovers CapFrameX's localhost MCP port from its configuration, log, running process, or default port. It exposes only the read-only capture data needed by the dashboards; CapFrameX's MCP endpoint itself remains bound to localhost and is not directly exposed through the dashboard tunnel.

The main dashboard shows the latest completed capture. The Capture Analyzer provides:

- a list of completed captures;
- raw frametime graphs and range-specific FPS statistics;
- recorded CapFrameX sensor series;
- synchronized hover inspection across frame and hardware metrics;
- configurable core and additional metric cards.

## Remote access

The server accepts only loopback clients. If temporary remote access is required, place a trusted tunnel in front of the local port, for example:

```powershell
tmole.exe 8080
```

Treat the generated URL as sensitive and stop the tunnel when the troubleshooting session is complete.

## Analysis notes

Performance Lab deduplicates canonical telemetry using HWiNFO's polling timestamp. Because that timestamp has one-second granularity, use a 1000 ms HWiNFO polling interval for canonical capture analysis. The KUM-FPS bootstrap configures this automatically.

FPS percentiles are calculated from HWiNFO polling samples. They are useful for trend analysis, but they are not true per-frame 1% or 0.1% lows. Raw PresentMon frame events are required for exact frame-level analysis.

CPU PPT, TDC, and EDC readings represent limit utilization, not percentages of time spent throttling. Actual throttling is reported only when HWiNFO exposes a corresponding status signal.

For a useful gaming capture:

- select the intended target FPS before capture;
- record 60–120 seconds of representative gameplay;
- keep menus and loading screens outside the measured lap;
- use a 1000 ms HWiNFO polling interval for canonical trend analysis.

## Export formats

The **Session** menu provides two analysis-oriented exports:

- **AI analysis JSON** — scope metadata, source mappings, summaries, diagnostics, warnings, and canonical telemetry samples.
- **Analysis telemetry CSV** — one row per HWiNFO update with wide columns for FPS, frame time, CPU, GPU, memory, power, temperature, and limit signals.

Missing or ambiguous readings are exported as `null` instead of being silently replaced with unrelated sensors.

## Version history

See [CHANGELOG.md](CHANGELOG.md) for release highlights. Every published version is available as an annotated Git tag.

## Files

- `hwinfo-performance-lab.ps1` — shared-memory reader, local HTTP server, API, and dashboard
- `START-PERFORMANCE-LAB.bat` — Windows launcher
- `INSTALL-KUM-FPS.ps1` / `.bat` — idempotent full-stack bootstrap installer
- `README-bootstrap.md` — bootstrap behavior, flags, logs, and limitations
