HWiNFO PERFORMANCE LAB v6.7
===========================

CUSTOMIZABLE TOP OVERVIEW
-------------------------
Each top panel now has an Edit button:
- Gaming
- GPU
- CPU
- Memory

Edit lets you:
- show/hide individual summary metrics
- drag selected metrics to reorder them
- reset that category to defaults

You can also drag visible metrics directly inside a category to reorder them.

The overview selection/order is saved locally and included in Export setup /
Import setup.

CPU THROTTLING SEMANTICS
------------------------
The default CPU overview is simplified.

Instead of showing three separate HTC / PROCHOT status rows plus several limit
percentages, it shows one primary:

  Thermal throttling: OK / ACTIVE

ACTIVE is reported only when an actual thermal-protection signal exposed by
HWiNFO is active:
- Thermal Throttling (HTC)
- Thermal Throttling (PROCHOT CPU)
- Thermal Throttling (PROCHOT EXT)

This is the meaningful "CPU is reducing/limiting itself for thermal protection"
summary.

Detailed metrics remain available through Edit:
- Thermal Limit %
- PPT Limit %
- TDC Limit %
- EDC Limit %

Those are resource/limit utilization values and are NOT themselves percentages
of throttling time.

GPU
---
GPU also gets a single Thermal throttling status when HWiNFO exposes an explicit
GPU thermal/performance-limit signal.

If the hardware/driver does not expose an explicit status, it remains "—"
rather than guessing from temperature.

DEFAULT CPU OVERVIEW
--------------------
- Total usage
- Max thread
- Temperature
- Package power
- Effective clock
- Thermal throttling
- PPT limit

Target FPS Off and all prior v6.6 features remain available.
