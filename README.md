HWiNFO PERFORMANCE LAB v6.5
===========================

IMPORTANT SEMANTICS FIX
-----------------------
Previous versions could incorrectly label Ryzen "Thermal Limit %" and
"PPT Limit %" values as throttling.

That was wrong.

CPU overview now separates:

Resource / headroom indicators:
- Thermal Limit %
- CPU PPT Limit %
- CPU TDC Limit %
- CPU EDC Limit %

Actual throttling/status indicators:
- Thermal Throttling (HTC)
- Thermal Throttling (PROCHOT CPU)
- Thermal Throttling (PROCHOT EXT)

The actual throttling indicators display:
  OK
or
  ACTIVE

instead of confusing 0.00% / 1.00% values.

MEANING
-------
Thermal Limit %
  How close the CPU is to its configured thermal limit.
  It is not "percent of time throttling".

PPT Limit %
  Usage of the Package Power Tracking budget.

TDC Limit %
  Usage of the sustained/thermal-design current budget.

EDC Limit %
  Usage of the electrical/peak current budget.

Reaching one of these resource limits can constrain boost behavior, but a value
below 100% is not by itself an active throttling flag.

HTC / PROCHOT CPU / PROCHOT EXT
  These are actual thermal-throttling status signals.

HEALTH COLORS
-------------
For Thermal/PPT/TDC/EDC limit percentages:
  < 90%   neutral
  >= 90%  warning
  >=100%  critical

For actual throttling status:
  OK      neutral
  ACTIVE  critical/red

Target FPS can still be set to Off in Settings.
