HWiNFO PERFORMANCE LAB v3
=========================

Purpose
-------
A lightweight remote debugging dashboard built on HWiNFO Shared Memory.

Highlights
----------
- Reads ALL HWiNFO readings automatically.
- Pin any sensor to the top.
- Pins persist in your browser via localStorage.
- Each pin has its own live graph.
- Graph windows: 60 sec / 5 min / 15 min / 30 min.
- Each pin can display:
    * Current
    * Session minimum
    * Session maximum
    * Session average
    * All values
- Session stats are calculated by this dashboard from scratch.
- "Reset session" clears:
    * local graph history
    * session min/max/average
    * sampled FPS percentiles
  It intentionally does NOT reset HWiNFO's own built-in Min/Max/Avg.
- FPS analysis:
    * session average
    * sampled P1 FPS
    * sampled P0.1 FPS
    * session min/max
    * sampled frame-time P99
    * sampled frame-time max
- CSV export for pinned sensor history.
- Search through every HWiNFO reading.
- "Pin essentials" automatically pins common gaming-debug metrics.

IMPORTANT ABOUT 1% LOW / 0.1% LOW
----------------------------------
The dashboard receives HWiNFO sensor samples at HWiNFO's sensor polling rate.
Therefore "Sampled P1" and "Sampled P0.1" are percentiles of those samples.

They are useful for long-session trend/debugging, but they are NOT a true
per-frame 1% low / 0.1% low calculation from raw PresentMon frame events.

A future version can integrate PresentMon directly if exact frame-level
percentiles are required.

SETUP
-----
1. Start HWiNFO in Sensors-only mode.
2. Enable HWiNFO -> Settings -> Shared Memory Support.
3. Run START-PERFORMANCE-LAB.bat
4. Open:
       http://localhost:8080
5. When local access works, run:
       tmole.exe 8080
6. Open the generated HTTPS Tunnelmole URL remotely.

NETWORKING
----------
The bridge accepts localhost IPv4 and IPv6 (127.0.0.1 / ::1), which fixes
Windows localhost resolution issues with Tunnelmole.

The bridge rejects direct non-loopback clients. Tunnelmole is the public layer.

TIPS
----
- Start with "Pin essentials", then remove readings you do not care about.
- For gaming diagnosis, useful pins normally include:
    FPS
    Frame time
    GPU Core Load
    GPU Temperature
    GPU Power
    GPU Clock
    GPU Memory usage
    Total CPU Usage
    CPU Package/Tctl temperature
    CPU Package Power
    CPU Effective Clock
    Physical Memory Load
- For more time resolution, lower HWiNFO's sensor polling interval carefully.
  A lower interval gives more samples, but also adds a little more monitoring work.
