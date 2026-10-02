HWiNFO PERFORMANCE LAB v6.4
===========================

OVERVIEW EXPANSION
------------------
Gaming:
- FPS
- Frame Time
- CPU Busy
- CPU Wait
- GPU Busy
- GPU Wait
- GPU Latency
- Display Latency

GPU:
- Load
- Temperature
- Hotspot / junction temperature
- Power
- Core clock
- Memory clock
- Fan
- Throttle / performance-limit status

CPU:
- Total usage
- Max thread/core usage
- Temperature
- Package power
- Effective clock
- PPT / power-limit metric
- Thermal throttling
- Power throttling / power-limit status

Memory:
- RAM load
- RAM used
- RAM available
- Committed memory
- VRAM used
- VRAM load
- Page file
- Memory/ECC/WHEA-related error reading when HWiNFO exposes one

GPU POWER FIX
-------------
The dashboard no longer requires the reading to be literally named "GPU Power".
It scores HWiNFO readings by label AND unit and supports names such as:
- GPU ASIC Power
- GPU Total Board Power
- Total Board Power
- GPU Board Power
- GPU Chip Power
- GPU Power
- Graphics Power
- GPU PPT

A W/Watt reading is strongly preferred.

TARGET FPS OFF
--------------
Settings -> Target FPS -> Off

When Off:
- FPS is not colored against a target.
- Frame Time is not colored against a frame budget.
- CPU Busy / GPU Busy are not colored against a frame budget.
- PresentMon latency metrics are not colored against a frame budget.

Temperature, memory-pressure, throttling and hardware-error health colors still work.

NOTE
----
Not every GPU/CPU exposes every HWiNFO sensor. A dash means the matching sensor
is not available in the current HWiNFO reading set, not necessarily that the
hardware does not support the feature.
