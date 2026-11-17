# Flight counter

| 1x2 | 2x1 | 2x2 |
| --- | --- | --- |
| ![Flight counter at 1x2](../assets/panels/flight-counter/1x2.png) | ![Flight counter at 2x1](../assets/panels/flight-counter/2x1.png) | ![Flight counter at 2x2](../assets/panels/flight-counter/2x2.png) |

Displays the model's selected flight total and highlights an AeroGrid-detected active flight.
Flight tracking is shared by AeroGrid dashboards and does not require a visible
Flight counter.

## Settings

![Flight counter panel settings](../assets/editor/flight-counter-settings.png)

| Setting | Default | What it does |
| --- | --- | --- |
| **Label** | FLT | Panel heading. Clear it to restore the default. |

Configure arming, detection, optional sounds, and **Flight count source**
in [Model settings](../user-guide/model-settings.md#flight-detection).
Those settings apply across the model's dashboards; this panel only configures
its label. For migration, see
[Older layouts](../user-guide/model-settings.md#older-layouts).

## Behavior

Each confirmed flight start increments AeroGrid's own persistent total once.
Choose **AeroGrid**, **GV9**, or **GV8:GV9** as the displayed source in Model
settings. External values are read from flight mode 0 and never written.
AeroGrid keeps its own count regardless of the displayed source; the totals
can differ because flight detection is independent.

Detection continues on hidden dashboards and does not depend on the number of
counter panels.
Telemetry loss or reducing motor output after confirmation does not end a
flight. Continuous disarming for the configured end window does; rearming
within that window keeps the same flight open. An unavailable arm reading
cannot confirm disarming.

If dashboard arm conditions conflict or settings change during a flight, the
current flight finishes using its original condition and output. New flights
wait until the configuration is consistent.

The [Session reset switch](../user-guide/model-settings.md#session-reset)
cancels detection and clears its output without changing flight totals.
Disarm before another flight can be counted. AeroGrid does not write flight CSV files.

AeroGrid supports totals up to 16,777,215. Its total persists through transmitter
restarts, but in-flight detection state does not. Changing model or restarting
during a flight can lose its history and qualify it again.

## States

| Condition | Presentation |
| --- | --- |
| Resting or qualifying | Count and normal styling, without a badge. |
| Qualified flight or pending disarm timeout | Count, blue active styling, and `IN-FLIGHT` badge. |
| Confirmed completion | Count retained and normal styling restored. |
| Selected count unavailable or invalid | `--` and an `N/A` badge. |
| Configuration or persistence failure | Actionable service error; resolve it before relying on tracking. |
