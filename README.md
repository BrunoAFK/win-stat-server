HWiNFO PERFORMANCE LAB v6.9
===========================

TOP BAR
-------
Lap navigation is now a single compact compound control:
  [ Lap 1 · Current  v | + Lap ]

The separate "View" label is gone.

RESET LAPS
----------
Session -> Reset laps

Deletes the lap markers and starts a fresh Lap 1 now.

It does NOT delete full-session telemetry, so the previous data remains visible
under "All session".

Session -> Reset entire session remains the destructive option that deletes:
- pinned telemetry history
- laps
- FPS analysis
- local session timer/history

PINNED TELEMETRY
----------------
Pinned telemetry now has:
  Hide pinned / Show pinned

The choice persists and is included in Export setup / Import setup.

FPS ANALYSIS POSITION
---------------------
FPS session analysis now has:
  Move up / Move down

This moves the entire FPS analysis section above or below Pinned telemetry.
The position persists and is exported/imported with the dashboard setup.

COMPACT FPS SETTINGS
--------------------
FPS source and Frame-time source no longer consume a permanent full-width row.

They are inside:
  Analysis settings v

The compact FPS header now contains:
- analysis elapsed time
- Analysis settings dropdown
- Reset analysis
- Move up/down

All v6.8.1 lap/session behavior and earlier functionality are retained.
