HWiNFO PERFORMANCE LAB v6
=========================

V6 UI REDESIGN
--------------
The feature-heavy top toolbar from v5 has been replaced with a compact command bar:

  Search | Presets | Dashboard | Session | Settings

All secondary controls are grouped into polished popover menus.

Presets
  - Gaming
  - GPU
  - CPU
  - Memory
  - All essentials

Dashboard
  - Expand / collapse all sensor groups
  - Show / hide all pinned graphs
  - Choose the large pinned-card value
  - Apply large-value mode to all cards
  - Clear pinned dashboard

Session
  - Pause / resume collection
  - Reset session statistics/history
  - Export telemetry CSV

Settings
  - Graph history window
  - Browser refresh interval
  - System / Dark / Light appearance
  - Export dashboard setup
  - Import dashboard setup

V5 FEATURES RETAINED
--------------------
- Robust FPS and frame-time source auto-detection
- Manual FPS / frame-time source selection
- Gaming / GPU / CPU / Memory categorisation
- Hoverable graphs with exact sample values
- Drag sensors to pin
- Drag pinned cards to reorder
- Current / Session Min / Session Avg / Session Max always visible
- Large card value selector changes only the headline value
- Session reset
- Sampled FPS percentiles
- CSV telemetry export
- Portable dashboard JSON export/import
- Cross-PC sensor remapping by HWiNFO sensor/label/unit
- Dark / Light / System mode
- Windows IPv4 + IPv6 localhost support for Tunnelmole

SETUP
-----
1. Run HWiNFO in Sensors-only mode.
2. Enable HWiNFO -> Settings -> Shared Memory Support.
3. Run START-PERFORMANCE-LAB.bat.
4. Open http://localhost:8080
5. Once local access works, run: tmole.exe 8080
