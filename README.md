HWiNFO PERFORMANCE LAB v6.1
===========================

PATCHES
-------
1. Fixed the empty "Nothing pinned..." tile staying in the Pinned Telemetry grid
   after the first real cards are added.

2. Expanded Gaming / PresentMon essentials:
   - FPS
   - Frame Time
   - CPU Busy
   - CPU Wait
   - GPU Busy
   - GPU Wait
   - GPU Latency
   - Display Latency

   Metrics only appear when HWiNFO/PresentMon exposes them for the current game.

3. The Gaming essential preset now attempts to pin the whole frame pipeline above.

PRESENTMON INTERPRETATION
-------------------------
CPU Busy:
  Time the CPU spent generating the frame.

CPU Wait:
  Time the CPU waited before it could begin generating the next frame.

GPU Busy:
  Time the GPU was actively executing work for the frame.

GPU Wait:
  Time the GPU was idle while the frame was progressing through GPU work.

GPU Latency:
  Time from frame start until GPU work begins.

Display Latency:
  Time from frame start until the frame reaches the display, when available.

These are durations in milliseconds, not percentages.

SETUP
-----
1. Start HWiNFO Sensors-only.
2. Enable Shared Memory Support.
3. Run START-PERFORMANCE-LAB.bat.
4. Open http://localhost:8080
5. Then expose with tmole.exe 8080 if needed.
