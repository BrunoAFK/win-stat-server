HWiNFO PERFORMANCE LAB v6.7.2
=============================

TYPOGRAPHY SCALE
----------------
Settings -> Minimum font size

Available values:
- 11 px
- 12 px
- 13 px
- 14 px
- 15 px
- 16 px

The selected value is a true minimum:
no dashboard text is intentionally rendered smaller than it.

Larger typography scales proportionally from the same setting, so choosing
14 px does not merely enlarge tiny labels; headings, values, menus and card
text grow together while preserving visual hierarchy.

Example:
Minimum font = 11 px
  old 8/9/10/11 px text -> 11 px minimum
  23 px heading         -> 23 px
  29 px pinned value    -> 29 px

Minimum font = 14 px
  smallest text         -> 14 px
  former 23 px heading  -> ~29 px
  former 29 px value    -> ~37 px

The setting:
- persists in the browser
- is included in Export setup
- is restored by Import setup
- triggers chart redraw after font/layout changes

This build is based on the V6.7.1 runtime hotfix, so the restored HWiNFO
sampling / pinned-card / graph functions are retained.
