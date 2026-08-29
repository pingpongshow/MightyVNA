# Calibration

MightyVNA applies calibration **on the Mac**, from raw sweeps. Your instrument's own calibration is
never touched, so you can keep a field calibration in the device while using a more accurate host
calibration on the desk.

Implemented in `Sources/VNACore/Model/Calibration.swift` and `CalKit.swift`.

## The one-port model

A reflectometer's systematic errors reduce to three terms: directivity `e00`, source match `e11`, and
reflection tracking, which only ever appears combined with the others as `Δe = e00·e11 − e10·e01`.
What the instrument measures for an actual load `Γa` is

```
      e00 − Δe·Γa
Γm = --------------
      1 − e11·Γa
```

Rearranged, that is linear in the three unknowns:

```
e00 − Γ·Δe + Γm·Γ·e11 = Γm
```

Three standards give three equations, solved per frequency point by `solve3x3` with partial pivoting.
Correction then inverts the relation:

```
      Γm − e00
Γa = -------------
     Γm·e11 − Δe
```

`CalibrationTests.testSOLTRecoversKnownLoadsWithIdealStandards` synthesises measurements from known,
frequency-varying error terms and checks the corrected result matches the true load to 1e-9.

## Standards are not ideal

Real open, short and load standards are modelled the way Keysight and the Touchstone world describe
them: an offset transmission line terminated by a lumped element.

- **Open**: fringing capacitance `C(f) = C0 + C1·f + C2·f² + C3·f³`, so `Γ = (1 − Z0·jωC)/(1 + Z0·jωC)`
- **Short**: residual inductance `L(f) = L0 + L1·f + L2·f² + L3·f³`, so `Γ = (jωL − Z0)/(jωL + Z0)`
- **Load**: `Z = R + jωL`
- **Offset**: `Γ ← Γ · e^(−2αl) · e^(−2jβl)` with `βl = 2πf·delay` and the HP loss model
  `αl = (loss · delay)/(2 · Z0) · √(f / 1 GHz)`

Using the ideal kit (`Γ = +1`, `−1`, `0`) reproduces what the NanoVNA firmware itself assumes. Entering
your kit's real coefficients is what buys accuracy above a few hundred megahertz.

## What the calibration can correct

MightyVNA picks the strongest correction the measured standards allow, and the status bar and
calibration panel say which one is in force:

| Mode | Needs | Corrects |
|---|---|---|
| One-port | open, short, load on port 1 | S11 |
| One-port + forward response | the above plus a through | S11 fully; S21 for tracking and isolation |
| **Full two-port (12-term)** | open/short/load on **both** ports, plus a through | S11, S21, S12 and S22 together, including both port matches |

The 12-term mode needs an instrument that measures the reverse direction. Every NanoVNA measures
forward only, so it tops out at forward response; a LibreVNA reaches the full twelve terms.

## Transmission

Two modes:

**Through normalisation** (default) — isolation is subtracted, then S21 is divided by the through
measurement corrected for the through standard's own delay and loss:

```
Et  = (S21_thru − Ex) / S21_ideal_thru
S21 = (S21_measured − Ex) / Et
```

**Enhanced response** — additionally removes the interaction between port-1 source match and the DUT's
input reflection, using the load match `El` recovered by applying the one-port correction to the S11
measured while the through was connected:

```
S21 = (S21_measured − Ex)/Et · (1 − Es·El)/(1 − Es·S11_corrected)
```

This is an improvement, not a substitute for a real two-port calibration: a forward-only instrument
never measures the reverse direction, so `S22` and `S12` are unknown and the residual `S12·S21` term
cannot be removed.

One consequence is worth stating plainly, because it surprises people: on a forward-only instrument the
corrected S11 is the DUT's **input reflection with port 2 terminated in the instrument's own load
match** — that is, `S11 + S21·S12·ELF / (1 − S22·ELF)` — not the DUT's isolated S11. For a one-port DUT
(an antenna, a load) the two are identical and the correction is exact. For a two-port DUT they differ,
and only a real two-port calibration separates them.

## Full two-port (12-term)

When standards have been measured on both ports and the instrument returns all four S-parameters,
MightyVNA solves the complete twelve-term model: directivity, source match, reflection tracking,
isolation, transmission tracking and load match, in each of the two directions.

The forward terms come from the port-1 standards exactly as above; the reverse terms come from the
port-2 standards by the same three-standard solve. The through then supplies four more:

- forward load match `ELF` = the through's port-1 reflection, corrected with the forward one-port terms
- reverse load match `ELR` = the through's port-2 reflection, corrected with the reverse terms
- `ETF = (S21m_thru − EXF)·(1 − ESF·ELF) / S21_ideal`
- `ETR = (S12m_thru − EXR)·(1 − ESR·ELR) / S12_ideal`

Correction then solves all four parameters simultaneously. With

```
A = (S11m − EDF)/ERF     B = (S21m − EXF)/ETF
C = (S22m − EDR)/ERR     D = (S12m − EXR)/ETR
Δ = (1 + A·ESF)(1 + C·ESR) − B·D·ELF·ELR
```

the corrected parameters are

```
S11 = [A(1 + C·ESR) − ELF·B·D] / Δ
S21 = [B(1 + C(ESR − ELF))]    / Δ
S12 = [D(1 + A(ESF − ELR))]    / Δ
S22 = [C(1 + A·ESF) − ELR·B·D] / Δ
```

`TwoPortCalibrationTests` generates measurements from a known, frequency-varying twelve-term error
model and checks the correction inverts it: a mismatched attenuator, a through, an open/open and a
non-reciprocal amplifier (3.2 forward gain, 0.01 reverse) all come back to within 1e-7.

### Practical two-port sequence

1. Set the sweep you will measure over.
2. Open, short, load on port 1.
3. Open, short, load on port 2 — the same standards, moved across.
4. Isolation: loads on both ports, nothing connecting them. Optional, but it is what buys you dynamic
   range on a high-rejection filter.
5. Through: connect port 1 to port 2.
6. The panel should now read **Full two-port (12-term)**.

## Interpolation

Error terms are stored on the grid they were measured on. When the sweep changes, they are linearly
interpolated onto the new grid, so zooming into part of a calibrated span keeps working. The status
bar and calibration panel warn when the sweep extends past the calibrated range, where the terms are
clamped to the edge values.

## How good is it?

The calibration panel shows **residual directivity**: the load standard corrected back through the
solved error terms, compared with its ideal value, in dB. Below −40 dB is a good calibration; a number
close to 0 dB means something is wrong (a standard measured on a different span, a loose connector, or
a sweep that moved between steps).

## Practical sequence

1. Set the sweep you actually want to measure over — calibration is only valid inside it.
2. Choose the cal kit that matches your standards.
3. Open, Short, Load on CH0. Leave the cable you will use attached; you are calibrating out the cable too.
4. For transmission work: Isolation (loads on both ports, nothing connecting them), then Through.
5. Check the residual directivity, then measure.
