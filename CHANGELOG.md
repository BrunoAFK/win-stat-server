# Changelog

This project follows semantic versioning for its tagged releases.

## v7.1.0

- Require positive semantic sensor-name matches before units can refine mappings.
- Separate GPU limit utilization from explicit throttling and limited-status signals.
- Add mapping diagnostics, confidence, rejection reasons, duplicate-source checks, and capture warnings.
- Export missing or ambiguous VRAM and PresentMon latency readings as `null`.
- Extend the analysis JSON format to schema v2.

## v7.0.0

- Add a canonical telemetry stream independent of pinned dashboard cards.
- Add structured AI analysis JSON export.
- Add wide-format analysis CSV export with one row per HWiNFO update.
- Add scope summaries for FPS, frame time, CPU, GPU, thermals, power, and hardware limits.

## v6.9.2

- Make Search consume available command-bar space while keeping menus compact.
- Move lap navigation to the right and improve narrow-window wrapping.
- Correct the stale page version label.

## v6.9.1

- Add live, animated pinned-grid reordering.
- Add temporary insertion placeholders when sensors are dragged into the grid.
- Remove the permanent drop-target strip.

## v6.9.0

- Consolidate lap navigation into a compact compound control.
- Add non-destructive lap reset.
- Add persistent pinned-telemetry visibility and movable FPS analysis.
- Move FPS source controls into a compact analysis settings menu.

## v6.8.1

- Move lap controls into the main command bar.
- Simplify the lower status strip to informational telemetry.

## v6.8.0

- Add non-destructive laps and current-lap, historical-lap, and full-session scopes.
- Apply the selected scope to charts, statistics, FPS analysis, and CSV export.
- Add a dedicated FPS analysis reset separate from the full session reset.
- Retain pinned telemetry for the full browser session.

## v6.7.2

- Add configurable minimum font size and proportional typography scaling.
- Persist typography settings and include them in dashboard configuration exports.

## v6.7.0

- Make Gaming, GPU, CPU, and Memory overview panels configurable and reorderable.
- Combine explicit CPU thermal-protection signals into a single status.
- Keep resource-limit utilization separate from actual throttling.

## v6.6.0

- Add per-card control visibility and global Show all/Hide all actions.
- Persist compact-card preferences in dashboard configuration exports.

## v6.5.0

- Correct Ryzen Thermal, PPT, TDC, and EDC limit semantics.
- Separate resource utilization from HTC and PROCHOT throttling status.
- Display explicit throttling signals as `OK` or `ACTIVE`.

## v6.4.0

- Expand Gaming, GPU, CPU, and Memory overview metrics.
- Improve GPU power sensor detection across vendor-specific labels.
- Add an Off setting for target-FPS-dependent health coloring.

## v6.3.0

- Improve dropdown, menu, heading, and card-control readability.

## v6.2.0

- Add warning and critical health colors.
- Add configurable target FPS and derived frame budgets.
- Add generic temperature and memory-pressure heuristics.
- Prevent telemetry refreshes from recreating pinned-card controls.

## v6.1.0

- Expand Gaming essentials with PresentMon CPU, GPU, and display pipeline metrics.
- Remove the empty placeholder after the first card is pinned.

## v6.0.0

- Replace the large toolbar with a compact command bar.
- Group controls into Presets, Dashboard, Session, and Settings menus.

## v5.0.0

- Improve FPS and frame-time source detection and allow manual overrides.
- Add Gaming, GPU, CPU, and Memory presets and category views.
- Add dark, light, and system themes.
- Add portable JSON dashboard configuration with cross-PC sensor remapping.

## v4.0.0

- Update live values in place so open controls remain stable.
- Add configurable browser polling, freshness indicators, and chart tooltips.
- Add pinned-card reordering, sensor drag-and-drop, and rolling averages.

## v3.0.0

- Introduce the Performance Lab dashboard.
- Add persistent pins, live graphs, session statistics, sampled FPS analysis, and CSV export.
- Add common gaming-debugging essentials.

## v2.1.0

- Support both IPv4 and IPv6 localhost connections.
- Reject requests that do not originate from a loopback address.

## v2.0.0

- Replace the HWiNFO Gadget/VSB interface with direct shared-memory access.
- Expose every available HWiNFO sensor and a JSON endpoint.

## v1.0.0

- Add the initial local web bridge for HWiNFO Gadget/VSB readings.
