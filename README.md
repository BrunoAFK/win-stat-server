HWiNFO PERFORMANCE LAB v5
=========================

SETUP
-----
1. Start HWiNFO in Sensors-only mode.
2. Enable HWiNFO -> Settings -> Shared Memory Support.
3. Run START-PERFORMANCE-LAB.bat.
4. Open http://localhost:8080
5. After local testing works, run: tmole.exe 8080

V5 HIGHLIGHTS
-------------
- Robust FPS / frame-time source detection.
- Manual FPS source and frame-time source selectors.
- Session FPS analysis now records ONE sample per HWiNFO source update, not one
  duplicate sample per browser refresh.
- Essential presets split into:
    Gaming
    GPU
    CPU
    Memory
    All essentials
- Category overview for Gaming / GPU / CPU / Memory.
- Category filters in the full HWiNFO sensor browser.
- Pinned-card dropdown changes ONLY the large headline value.
  Current / Session Min / Session Avg / Session Max always stay visible.
- Hoverable live graphs with exact sampled time/value.
- Drag and drop:
    sensor -> pinned dashboard
    pinned card -> reorder
- Expand all / Collapse all.
- Global graph on/off.
- Global large-value mode.
- Dark / Light / System theme.
- Export / Import dashboard setup as JSON.
- Exported setup stores sensor names/labels, not just internal numeric IDs, so
  importing on another PC can remap matching HWiNFO readings automatically.
- Export setup includes:
    pin list and order
    per-card mode / graph / smoothing
    FPS and frame-time source overrides
    graph window
    browser polling interval
    theme
    sensor category filter
- Export session telemetry to CSV.
- Reset session clears local graph/statistics/percentile history without touching
  HWiNFO's own built-in Min/Max/Avg counters.

FPS NOTE
--------
The FPS percentiles in this dashboard are percentiles of HWiNFO polling samples.
They are useful for remote troubleshooting and trends, but they are NOT exact
per-frame 1% low / 0.1% low statistics. Exact lows require raw PresentMon frame
events, which can be integrated separately later.

CROSS-PC SETUP
--------------
On the configured PC:
  Export setup -> save JSON.

On another PC:
  Start HWiNFO + Performance Lab -> Import setup -> choose JSON.

The importer first tries exact Sensor + Label + Unit matching, then falls back
to label-based matching. Hardware-specific sensors that do not exist on the new
PC are skipped and the dashboard reports how many could not be mapped.

NETWORKING
----------
The server supports Windows localhost over both IPv4 and IPv6 for Tunnelmole,
while rejecting direct non-loopback clients. Tunnelmole remains the public layer.
