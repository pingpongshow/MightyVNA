# MightyVNA user guide

## First run

Plug the analyser in over USB and switch it on.

- **NanoVNA family** — appears as a serial port (`/dev/cu.usbmodem…`). Pick it in the **Analyser**
  panel and press **Connect**; the protocol (text shell or V2 binary) is detected automatically.
- **LibreVNA** — appears as a raw USB device, no serial driver needed. It identifies itself, so there
  is nothing to choose. Close the LibreVNA GUI first: only one application can hold the device.

No hardware to hand? Two simulators are built in:

- **NanoVNA sim** — a dual-band antenna on CH0 and a 300 MHz bandpass filter on CH1.
- **LibreVNA sim** — a full two-port bandpass filter measured in both directions, so S12, S22 and the
  12-term calibration all work.

The **Measures** row in the Analyser panel tells you what the connected instrument can actually
provide: `S11 S21`, or `S11 S21 S12 S22` in green for a true two-port device. Everything else in the
app follows from that — the channel pickers, the calibration steps, the exports and the readouts.

The status bar along the bottom always shows: connection, sweep range, point count, segment count when
the sweep is split, calibration state, sweep time and battery voltage.

## Setting up a sweep

Type frequencies however you like — `144M`, `2.4 GHz`, `50k`, `145.500 MHz`, `1_000_000` all parse.
Switch between **Start / Stop** and **Centre / Span** with the segmented control.

**Presets** covers every amateur band from 630 m to 13 cm plus broadcast, airband, marine VHF, ISM,
GSM, GPS and Wi-Fi. "Zoom to markers" sets the span to the outermost enabled markers.

If you ask for more points than the hardware sweeps in one pass, MightyVNA splits the request into
segments and stitches them together. The status bar tells you how many passes that costs.

**Option-drag** across any rectangular plot to zoom the sweep to that span.

## Traces and panes

Each pane's header has a chart-type button (rectangular / Smith / polar / time domain), a chip per
trace, and a **+** to add one. Click a chip for its menu: hide, select, auto-scale, change format or
channel, remove.

Select a trace in the sidebar to get the full inspector: scale per division, reference value and
reference line position, smoothing, electrical delay, cable-loss compensation, line width and a custom
name. The wand next to the delay field fits the phase slope across the sweep and applies the delay that
flattens it — the fastest way to move the reference plane to the end of a jig or cable.

**Double-click** a plot to auto-scale every trace in it.

## Markers

Drag anywhere on a chart to move the active marker. On a Smith or polar chart, the marker snaps to the
nearest point on the trace.

Each marker can *track* a feature instead of sitting still: maximum, minimum, leftmost or rightmost
peak, the −3 dB points, or the frequency where reactance crosses zero. Bind a marker to a specific
trace so tracking follows the right curve.

Set **Delta from** on a marker to read differences instead of absolutes — the marker detail then shows
Δf, ΔS11 and ΔS21 against the reference marker.

## Calibrating

See [CALIBRATION.md](CALIBRATION.md) for the mathematics. The short version:

1. Set the sweep you will actually measure over.
2. Pick the cal kit. "Ideal" matches what the instrument's own firmware assumes; enter your kit's real
   coefficients under **Edit kit** for accurate work above a few hundred MHz.
3. Measure Open, Short and Load on port 1 — with the same cable you will use for the measurement.
4. On a two-port instrument, repeat the three standards on port 2. The panel shows those steps only
   when the connected hardware can use them.
5. For transmission work, add Isolation (loads on both ports, nothing connecting them) and Through.
6. The badge at the top of the panel tells you what you have earned: **One-port**, **One-port +
   forward response**, or **Full two-port (12-term)**.
7. Check **residual directivity** in the panel. Below −40 dB is good.

Calibration is applied on the Mac and interpolates onto any sweep grid, so you can zoom in afterwards
without recalibrating. Untick **Apply calibration to live data** at any time to see the raw measurement.

**On-device cal…** runs the instrument's own SOLT and memory slots, for when you want the calibration
to live in the analyser for field use.

## Time domain and cables

The **Time domain** inspector tab controls the transform: lowpass step (the usual choice for TDR),
lowpass impulse, or bandpass impulse for band-limited sweeps that cannot assume DC.

Resolution improves with sweep bandwidth; unambiguous range improves with a smaller frequency step.
Both are shown live, so you can tell immediately whether the sweep you have chosen can resolve what you
are looking for.

**Add TDR pane** puts a distance-axis plot on the grid.

The **Cable tools** panel finds the end of a cable, reports round-trip delay, and — if you type in the
true physical length — solves for the velocity factor. It also compares measured loss against catalogue
values for 16 common cable types.

## Analysis tools

- **Antenna** — resonance (reactance zero), minimum SWR and where it occurs, feedpoint impedance,
  SWR bandwidth at a threshold you choose, loaded Q, and how far off centre the resonance sits.
- **Filter** — insertion loss, −3/−6/−60 dB bandwidths, shape factor, passband ripple, stopband rejection.
- **Matching** — every two-element L-network that matches the measured load to your target impedance,
  with real component values, loaded Q, an estimated bandwidth and the residual SWR each network leaves.
  Also the quarter-wave transformer impedance and physical length for nearly real loads.

## Limits

A limit set binds to one trace and holds any number of segments, each an upper or lower bound sloping
between two frequencies. The panel shows PASS/FAIL live with the worst-case margin, and the limits draw
on the plot as dashed red lines.

## Getting data out

| What | How |
|---|---|
| Touchstone `.s1p` / `.s2p` | File ▸ Export, or the Data tab |
| CSV with derived values | File ▸ Export ▸ CSV |
| Clipboard | Data tab ▸ Copy |
| Plot image | File ▸ Export ▸ Plot image |
| Instrument screenshot | Data tab ▸ Capture, then Save PNG |
| Whole session | File ▸ Save — traces, markers, calibration, memories and the live sweep |

On a two-port instrument, `.s2p` files carry real S12 and S22. From a NanoVNA they cannot: S12 is
written as a copy of S21 (reciprocity assumed) and S22 as zero, with a comment in the file saying so.

## LibreVNA acquisition settings

A LibreVNA gets its own sidebar panel:

- **IF bandwidth** — narrow lowers the noise floor, wide sweeps faster. The choices offered come from
  the limits the device reports.
- **Excitation** — output power, clamped to the device's own range. Turn it down for active DUTs.
- **Measure the reverse direction** — off halves the sweep time but drops S12 and S22, and with them
  the 12-term correction. The app falls back to NanoVNA-style behaviour while it is off.
- **Logarithmic frequency steps** — a log sweep instead of a linear one.

## Memory traces

**Store sweep** snapshots the current measurement. A memory can then be shown as its own trace, or used
as the divisor in **Live ÷ Memory** (normalisation — the classic way to remove a fixture's response) or
subtrahend in **Live − Memory**.

## The console

The **Console** tab is a full serial terminal onto the text shell, with a command suggestion list and a
live log of every byte exchanged. Useful for firmware settings the app does not expose, and for seeing
exactly what went wrong when a device misbehaves.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `Space` | run / stop sweeping |
| `⌘R` | single sweep |
| `⌘K` | connect |
| `⌘=` | auto-scale all traces |
| `⌘M` | store memory trace |
| `⇧⌘M` | add marker |
| `⌘N` / `⌘O` / `⌘S` | new / open / save session |
| `⇧⌘I` | import Touchstone |
