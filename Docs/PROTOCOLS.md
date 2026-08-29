# Protocol reference

MightyVNA implements three wire protocols. For serial devices, `DeviceSession.connect(to:preference:)`
tries the ASCII shell first and falls back to the V2 binary protocol, unless you force one in the
sidebar. Raw-USB instruments identify themselves by USB VID/PID, so no probing is needed.

---

## 1. ASCII shell

Used by the original NanoVNA, NanoVNA-H, NanoVNA-H4, and the SYSJOINT NanoVNA-F / F V2 / F V3.

USB CDC-ACM. Baud rate is nominal (115200 is set, but CDC ignores it). Commands are sent with `\r\n`.
The device echoes the command line, prints output, then the prompt `ch> `.

Implemented in `Sources/VNACore/Device/ASCIIShellDriver.swift`.

### Commands MightyVNA uses

| Command | Purpose |
|---|---|
| `version` | firmware banner, used for model identification |
| `info` | board info, build time |
| `help` | advertised command set — drives feature availability in the UI |
| `sweep <start> <stop> <points>` | set the sweep range |
| `scan <start> <stop> <points> 7` | fast path: sweep and dump `freq s11re s11im s21re s21im` per point |
| `frequencies` | one frequency per line |
| `data 0` / `data 1` | S11 / S21 as `re im` per line |
| `pause` / `resume` | stop and start the free-running sweep |
| `capture` | raw big-endian RGB565 framebuffer |
| `vbat` | battery in millivolts |
| `cal <reset\|open\|short\|load\|isoln\|thru\|done\|on\|off>` | on-device calibration |
| `save <n>` / `recall <n>` | on-device memory slots |
| `edelay <ps>`, `bandwidth <n>`, `power <n>` | instrument settings |

### The `scan` output mask

Newer firmware (DiSlord and derivatives) accepts a fourth argument to `scan` that selects what gets
printed: bit 0 = frequency, bit 1 = S11, bit 2 = S21. `7` gives all three, which is one round trip for
a whole sweep instead of four.

Older firmware either ignores the extra argument or prints a usage string. MightyVNA detects both:
if the response does not parse into at least half the requested points, it disables the fast path for
that connection and uses the universal sequence for the rest of the session.

### Point-count discovery

Firmware often has a fixed sweep length (101 on many builds, 201/301/401 on others). When the device
returns fewer points than were requested, `learnPointLimit` records the real limit on the device model.
`DeviceSession.sweep` then splits longer sweeps into contiguous segments of that size and stitches them
back onto the requested frequency grid.

### Screen capture

`capture` streams `width × height × 2` bytes of big-endian RGB565 with no header. Rather than trusting
the catalogue entry, MightyVNA reads until the stream goes idle, strips the echoed command and trailing
prompt, and matches the byte count against the known resolutions (320×240, 480×272, 480×320, 800×480,
320×480). The matched size is then remembered on the device info.

---

## 2. NanoVNA V2 binary protocol

Used by the NanoVNA V2 (S-A-A-2), V2 Plus4, LiteVNA and the SYSJOINT SV series.

Implemented in `Sources/VNACore/Device/V2BinaryDriver.swift`.

### Opcodes

| Byte | Meaning |
|---|---|
| `0x00` | NOP — a run of these resets a half-parsed command |
| `0x0D` | INDICATE — returns the protocol generation, `'2'` |
| `0x10` / `0x11` / `0x12` | read 1 / 2 / 4 bytes from a register |
| `0x18` | READFIFO: `[0x18, addr, count]` → `count × 32` bytes |
| `0x20` / `0x21` / `0x22` / `0x23` | write 1 / 2 / 4 / 8 bytes to a register |
| `0x28` | WRITEFIFO |

All multi-byte values are little-endian.

### Registers

| Address | Width | Meaning |
|---|---|---|
| `0x00` | 8 | sweep start, Hz |
| `0x10` | 8 | sweep step, Hz |
| `0x20` | 2 | sweep points |
| `0x22` | 2 | values averaged per frequency |
| `0x26` | 1 | raw samples mode |
| `0x30` | — | values FIFO (write 0 to clear, READFIFO to drain) |
| `0xF0`…`0xF4` | 1 | device variant, protocol version, hardware revision, firmware major, firmware minor |

### FIFO record (32 bytes)

| Offset | Type | Field |
|---|---|---|
| 0 | int32 | fwd0 real |
| 4 | int32 | fwd0 imaginary |
| 8 | int32 | rev0 real |
| 12 | int32 | rev0 imaginary |
| 16 | int32 | rev1 real |
| 20 | int32 | rev1 imaginary |
| 24 | uint16 | frequency index |
| 26 | — | reserved |

`S11 = rev0 / fwd0` and `S21 = rev1 / fwd0`. The frequency index lets the driver fill the sweep out of
order and detect missing points, which it retries until the sweep is complete or the deadline expires.

---

## Serial layer

`SerialPort` opens `/dev/cu.*` with `O_RDWR | O_NOCTTY | O_NONBLOCK`, claims it exclusively with
`TIOCEXCL`, clears `O_NONBLOCK`, and puts the line in raw mode (`cfmakeraw`, 8N1, no flow control,
`VMIN = VTIME = 0`). All timeouts are done with `select()`, so a hung device never blocks forever.

`SerialPortEnumerator` walks the IOKit registry for `IOSerialBSDClient` nodes, reads the callout device
path, then climbs the parent chain for `idVendor`, `idProduct` and `USB Product Name`. Ports are scored
so that likely analysers (STMicro VCP `0483:5740`, the V2 reference `04B4:0008`, anything whose product
name mentions VNA) sort to the top, and Bluetooth/debug ports are filtered out.


---

## 3. LibreVNA packet protocol

Used by the LibreVNA. Unlike every NanoVNA, this device is not a serial port: it exposes
vendor-specific USB bulk endpoints, and it measures all four S-parameters.

Implemented in `Sources/VNACore/Device/LibreVNAProtocol.swift` (codec) and `LibreVNADriver.swift`
(behaviour), against the firmware's own `Protocol.hpp`, protocol version 14.

### USB

| Property | Value |
|---|---|
| VID:PID | `0483:564E` and `0483:4121` |
| Interface | 0 |
| Data OUT | bulk endpoint `0x01` |
| Data IN | bulk endpoint `0x81` |
| Log IN | bulk endpoint `0x82` (not used by MightyVNA) |

`IOKitUSBBulkDevice` opens the device through IOUSBLib — the same user-space interface libusb uses on
macOS — so there is no external dependency and no kernel extension. It claims interface 0, finds the
pipes whose endpoint addresses match, and transfers with `WritePipeTO` / `ReadPipeTO` so a wedged
device can never block forever. If another application already holds the device (the LibreVNA GUI, for
example) the open fails with a message saying so.

### Packet framing

    [0x5A][uint16 length][uint8 type][payload…][uint32 CRC32]

- `length` is the total packet size, including the sync byte and the CRC.
- All multi-byte fields are little-endian.
- The CRC is CRC-32/ISO-HDLC (polynomial `0xEDB88320`, init and final XOR `0xFFFFFFFF`) computed over
  every byte before it.
- **Datapoint packets carry a CRC of zero.** The firmware deliberately skips the calculation there
  because it dominates the per-point transmit cost, so the decoder must accept a zero CRC for that
  packet type and only that type.

The decoder is incremental: it resynchronises past garbage, holds partial packets until the rest
arrives, and drops packets whose CRC does not match without losing the stream.

### Packet types used

| Value | Type | Direction |
|---|---|---|
| 5 | DeviceInfo | from device |
| 7 / 10 | Ack / Nack | from device |
| 15 | RequestDeviceInfo | to device |
| 20 | SetIdle | to device |
| 25 | DeviceStatus | from device |
| 26 | RequestDeviceStatus | to device |
| 27 | VNADatapoint | from device |
| 2 | SweepSettings | to device |
| 30 / 31 | Stop / StartStatusUpdates | to device |

### SweepSettings (31 packed bytes)

| Offset | Type | Field |
|---|---|---|
| 0 | uint64 | start frequency, Hz |
| 8 | uint64 | stop frequency, Hz |
| 16 | uint16 | points |
| 18 | uint32 | IF bandwidth, Hz |
| 22 | int16 | excitation start, 1/100 dBm |
| 24 | bitfield | bit 0 standby, 1 syncMaster, 2 suppressPeaks, 3 fixedPowerSetting, 4 logSweep, 5–6 syncMode |
| 25 | uint16 | bits 0–2 stages, 3–5 port1Stage, 6–8 port2Stage, 9–11 port3Stage, 12–14 port4Stage |
| 27 | int16 | excitation stop, 1/100 dBm |
| 29 | uint16 | dwell time, µs |

`stages` is the number of excitation stages minus one. A two-port sweep sets `stages = 1`,
`port1Stage = 0`, `port2Stage = 1`: port 1 is driven during stage 0 and port 2 during stage 1.

### DeviceInfo (57 packed bytes)

Reports protocol and firmware version, hardware revision, and the real limits: minimum and maximum
frequency, IF bandwidth range, maximum points, excitation power range and port count. MightyVNA adopts
these over its catalogue entry, so a device with different limits is handled correctly without a
code change.

### VNADatapoint

| Offset | Type | Field |
|---|---|---|
| 0 | uint64 | frequency (or µs in zero-span) |
| 8 | int16 | excitation level, 1/100 dBm |
| 10 | uint16 | point number |
| 12 | float × n | real parts |
| 12 + 4n | float × n | imaginary parts |
| 12 + 8n | uint8 × n | descriptors |

with `n = (payload length − 12) / 9`. Each descriptor is `stage << 5 | portMask`, where bits 0–3 select
the receiver (port 1–4) and bit 4 marks a reference channel.

S-parameters come out as a ratio of two readings from the same stage:

    S(i,j) = value(stage_j, receiver i, reference: false) / value(stage_j, receiver j, reference: true)

so a two-stage sweep yields S11 and S21 from stage 0, and S12 and S22 from stage 1.

One subtlety worth knowing: a reference descriptor also has its port bit set, so a loose mask test
would confuse a reference reading with a receiver reading. MightyVNA matches the reference bit
exactly, and there is a test for it.

### Sweep flow

1. `RequestDeviceInfo` → `DeviceInfo`, adopting the reported limits.
2. `SweepSettings` → `Ack`, after which the device free-runs and streams datapoints.
3. Collect points, starting at point 0 so two sweeps are never stitched together, until every point
   number has arrived.
4. `SetIdle` to stop the device between acquisitions.
