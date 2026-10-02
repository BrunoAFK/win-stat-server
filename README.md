HWiNFO PERFORMANCE LAB v6.8
===========================

LAPS
----
A session can now contain multiple non-destructive laps.

Default view:
  Current lap

Controls:
  New lap
  View:
    Current lap
    All session
    Lap 1
    Lap 2
    ...

Starting a new lap DOES NOT delete any data.

The selected scope affects:
- pinned telemetry Min / Avg / Max
- pinned telemetry charts
- FPS session analysis
- telemetry CSV export

When viewing a completed historical lap, its chart shows that whole lap.
Current-lap and all-session charts still obey the selected graph-window setting.

The card labels change with scope:
- Current lap -> Lap min / Lap avg / Lap max
- All session -> Session min / Session avg / Session max
- Historical lap -> Lap N min / avg / max

For a completed historical lap, "Current" becomes the final sample from that lap.

FPS ANALYSIS RESET
------------------
FPS session analysis now has its own:
  Reset FPS analysis

It clears ONLY:
- FPS analysis samples
- frame-time analysis samples
- FPS percentiles / ranges calculated from those samples

It does NOT clear:
- pinned telemetry history
- lap markers
- session timer
- hardware sensor history

Changing the FPS source or frame-time source automatically restarts FPS analysis
to prevent values from different sources being mixed.

FULL SESSION RESET
------------------
Session -> Reset session still performs the destructive full reset:
- pinned history
- all laps
- FPS analysis
- session timer

HWiNFO's own built-in Min/Max/Avg are never reset by this dashboard.

HISTORY
-------
Pinned telemetry is retained for the full in-browser session rather than being
trimmed to one hour, so "All session" really represents the current session.

CSV
---
Export telemetry CSV exports the currently selected scope (current lap, all
session, or a completed lap).

All prior v6.7.2 features remain:
- customizable overview
- aggregate thermal-throttling status
- health colors
- Target FPS Off
- portable setup export/import
- font-size scaling
- stable dropdowns during telemetry refresh
