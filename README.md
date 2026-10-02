HWiNFO PERFORMANCE LAB v6.2
===========================

V6.2
----
1. HEALTH COLORS
   Settings -> Health colors

   Normal values remain visually neutral.
   Only values outside the dashboard's generic troubleshooting thresholds are
   highlighted:
     yellow = warning
     red    = critical

   Health colors apply to:
     - pinned headline values
     - pinned Current / Session Min / Avg / Max values
     - Gaming / GPU / CPU / Memory overview numbers
     - full HWiNFO table
     - FPS/session percentile metrics where appropriate

   Deliberately NOT treated as "bad" just because they are high:
     - ordinary GPU utilization
     - ordinary CPU utilization
     - power consumption
     - clocks
     - CPU Wait / GPU Wait

   Those values are workload/context dependent.

2. TARGET FPS
   Settings -> Target FPS

   The selected target defines the frame budget used for:
     - FPS health
     - Frame Time health
     - CPU Busy / GPU Busy health
     - latency heuristics

   Example:
     144 FPS target = ~6.94 ms frame budget.

3. GENERIC TEMPERATURE / MEMORY HEURISTICS
   CPU:
     warning >= 85 C
     critical >= 95 C

   GPU core:
     warning >= 82 C
     critical >= 90 C

   GPU hotspot / junction:
     warning >= 95 C
     critical >= 105 C

   NVMe / SSD:
     warning >= 70 C
     critical >= 80 C

   RAM load:
     warning >= 85%
     critical >= 95%

   VRAM pressure:
     warning >= 90%
     critical >= 98%

   These are generic debugging thresholds, not manufacturer-specific safety
   limits. Exact component limits always take precedence.

4. DROPDOWN / REFRESH FIX
   Pinned cards are no longer synchronized/reinserted into the DOM on every
   telemetry refresh.

   Values and graphs update in place only.

   This fixes native select/dropdown menus blinking or closing every time HWiNFO
   refreshes. Card DOM is changed only when:
     - a pin is added/removed
     - cards are reordered
     - sensor topology changes
     - a dashboard setup is imported

SETUP
-----
1. Start HWiNFO Sensors-only.
2. Enable Shared Memory Support.
3. Run START-PERFORMANCE-LAB.bat.
4. Open http://localhost:8080
5. If needed, expose with:
     tmole.exe 8080
