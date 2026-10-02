HWiNFO PERFORMANCE LAB v7.0
===========================

ANALYSIS-FIRST EXPORT
---------------------
V7 adds a canonical telemetry stream that is collected independently of the
pinned dashboard.

This means important diagnostic readings are exported even if the user never
pinned them.

Canonical telemetry includes:
- FPS / Frame Time
- CPU Busy / Wait
- GPU Busy / Wait
- GPU Latency / Display Latency
- GPU utilization / temperature / hotspot / power / clocks / fan
- GPU power / temperature / current / voltage limit indicators when exposed
- CPU total / max thread / temperature / package power / effective clock
- CPU Thermal / PPT / TDC / EDC limit utilization
- HTC / PROCHOT / PROCHOT EXT actual throttle signals
- RAM / VRAM / pagefile / memory errors

EXPORT AI ANALYSIS JSON
-----------------------
Session -> Export AI analysis JSON

The JSON contains:
- selected scope (current lap / historical lap / all session)
- start/end timestamps
- target FPS and frame budget
- HWiNFO polling interval
- browser polling interval
- detected CPU / GPU names
- exact HWiNFO source mapping for every canonical metric
- summary statistics
- lap metadata
- interpretation notes
- all canonical telemetry samples

Important notes explicitly tell an AI that:
- percentiles are HWiNFO polling-sample percentiles, not true per-frame lows
- PPT/TDC/EDC are limit-utilization values, not "throttling percentages"
- HTC/PROCHOT and explicit GPU Limited readings are the actual status signals

WIDE ANALYSIS CSV
-----------------
Session -> Export analysis telemetry CSV

CSV is now wide-format:
one row = one HWiNFO source update.

Example columns:
timestamp_iso
elapsed_ms
lap_id
target_fps
hwinfo_poll_ms
fps
frame_time_ms
cpu_busy_ms
gpu_busy_ms
gpu_util_pct
gpu_temp_c
gpu_power_w
cpu_max_thread_pct
cpu_package_power_w
cpu_ppt_limit_pct
cpu_tdc_limit_pct
cpu_edc_limit_pct
...

This is substantially easier for spreadsheets, Python and AI tools to analyse
than the old long-format pinned-sensor CSV.

SCOPE ANALYSIS
--------------
The FPS section now includes a compact Scope analysis panel showing:
- median FPS
- P1 FPS
- frame-time P95
- target miss percentage
- CPU/GPU Busy median and P95
- GPU utilization median
- percentage of GPU samples >=95%
- GPU max temperature
- GPU median power
- CPU max-thread P95
- CPU max temperature
- CPU median package power
- PPT / TDC / EDC maximums

All metrics follow the currently selected lap/session scope.

DATA COLLECTION
---------------
Canonical analysis telemetry is collected once per actual HWiNFO source update,
not once per browser refresh.

Pinned telemetry remains independent.

Reset FPS analysis:
- resets only FPS-analysis samples

Reset laps:
- resets only lap markers

Reset entire session:
- clears pinned history
- clears canonical analysis telemetry
- clears FPS analysis
- resets laps and session timer
