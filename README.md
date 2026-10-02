HWiNFO PERFORMANCE LAB v4
=========================

WHAT THIS VERSION FIXES
-----------------------
- Dashboard updates values in place instead of rebuilding cards every poll.
  Open dropdowns therefore stay open during refresh.
- Browser polling defaults to 500 ms and can be changed to 250 ms / 500 ms / 1 s / 2 s.
- Live/stale indicator shows whether the browser is updating AND whether HWiNFO's own
  shared-memory poll timestamp is advancing.
- Chart hover shows the nearest sample timestamp and exact value.
- Pinned cards support drag-and-drop reordering.
- Sensor rows can be dragged into the pinned area.
- Global controls:
    Expand all sensor groups
    Collapse all sensor groups
    Graphs on/off for every pin
    Apply one display mode to all pins
    Clear all pins
- Per-card controls are persistent and are not recreated on each poll.
- Optional 5-second rolling-average graph per card.
- Reset Session clears dashboard-owned history/min/max/average/percentiles only.
- CSV export includes pinned history plus FPS/frame-time history.
- Pinned order and card options are saved in browser localStorage.

FPS ANALYSIS
------------
The P5/P1/P0.1 FPS and frame-time P95/P99 shown here are calculated from HWiNFO
polling samples. They are useful for remote troubleshooting and trends, but are NOT
the same as per-frame PresentMon 1% low / 0.1% low statistics.

SETUP
-----
1. Start HWiNFO in Sensors-only mode.
2. Enable HWiNFO -> Settings -> Shared Memory Support.
3. Run START-PERFORMANCE-LAB.bat
4. Open http://localhost:8080
5. When local access works, run:
       tmole.exe 8080
6. Open the generated HTTPS URL remotely.

TUNNEL NOTE
-----------
The bridge accepts localhost on IPv4 and IPv6 so Windows localhost resolution works
with Tunnelmole. Direct non-loopback access is rejected by the bridge; Tunnelmole is
the public-facing layer.
