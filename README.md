# HWiNFO Performance Lab

A lightweight Windows dashboard for inspecting live HWiNFO telemetry in a web browser. Performance Lab reads HWiNFO shared memory directly and presents gaming, CPU, GPU, memory, and PresentMon metrics without requiring a separate monitoring service.

The current release is **v7.1.0**.

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
- Local IPv4 and IPv6 access with non-loopback requests rejected

## Requirements

- Windows
- HWiNFO64 running in Sensors-only mode
- **Shared Memory Support** enabled in HWiNFO settings
- PowerShell with permission to run the included script
- A modern web browser

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

## Remote access

The server accepts only loopback clients. If temporary remote access is required, place a trusted tunnel in front of the local port, for example:

```powershell
tmole.exe 8080
```

Treat the generated URL as sensitive and stop the tunnel when the troubleshooting session is complete.

## Analysis notes

Performance Lab records one canonical telemetry sample per actual HWiNFO source update. This avoids duplicating samples when the browser refresh interval is faster than HWiNFO's polling interval.

FPS percentiles are calculated from HWiNFO polling samples. They are useful for trend analysis, but they are not true per-frame 1% or 0.1% lows. Raw PresentMon frame events are required for exact frame-level analysis.

CPU PPT, TDC, and EDC readings represent limit utilization, not percentages of time spent throttling. Actual throttling is reported only when HWiNFO exposes a corresponding status signal.

For a useful gaming capture:

- select the intended target FPS before capture;
- record 60–120 seconds of representative gameplay;
- keep menus and loading screens outside the measured lap;
- use a 500–1000 ms HWiNFO polling interval for trend analysis.

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
