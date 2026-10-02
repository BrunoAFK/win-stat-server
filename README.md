HWiNFO PERFORMANCE LAB v6.9.1
=============================

LIVE PINNED-GRID DRAG & DROP
----------------------------

The permanent "Drop a sensor here to pin it" strip is gone.

REORDERING EXISTING CARDS
-------------------------
Drag an existing pinned card.

While your mouse moves through the grid:
- the dragged card moves to the proposed position immediately
- surrounding cards reflow around it
- the reflow is animated
- you see the actual final arrangement before releasing the mouse

Drop commits the order.
Canceling the drag restores the previous order.

ADDING A NEW SENSOR
-------------------
Drag any row from "All HWiNFO sensors" into the pinned grid.

A temporary card-sized placeholder appears only while dragging:
  Pin here

The placeholder moves through the grid under the cursor and pushes the existing
cards into their prospective positions. Drop inserts the new sensor exactly
there.

There is no permanent drop-target row consuming dashboard space.

EMPTY DASHBOARD
---------------
An empty pinned grid simply shows:
  No pinned telemetry.

It still accepts dragged sensor rows.

All v6.9 features remain intact, including stable dropdowns during telemetry
refresh.
