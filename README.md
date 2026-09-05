# SyncCastReceiver

A small macOS daemon that turns a spare Mac into a **rate-locked LAN speaker**
for [SyncCast](https://github.com/vcxzvfe/synccast)'s local Stereo path.

SyncCast sends 48 kHz stereo PCM over UDP; this daemon plays it on a chosen
CoreAudio output device, sample-accurately locked to the sender's ring, so it
can be one leg of a stereo pair alongside the sender's own outputs. It is not
AirPlay: there is no re-encoding, no 2-second buffer, and no Apple stack in the
path. Typical end-to-end latency is **60–120 ms on Wi-Fi** and can be tuned
down to ~40 ms on a wired LAN.

```
SyncCast (sender)                        SyncCastReceiver
  ring ──► Int16 packets ──── UDP ──────► jitter ring ──► resampler ──► AUHAL ──► speakers
        └─ control/ping ──── TCP ───────► clock offset ──► PI loop ──────┘
                        Bonjour _synccast-pcm._udp
```

## How it stays in sync

* **Clock**: both ends timestamp with `mach_absolute_time` converted to
  nanoseconds — never wall clock. Every packet carries a `play_at_ns` in the
  *sender's* clock, meaning "this frame leaves the DAC at this instant".
* **Offset**: `ping`/`pong` give an NTP-style four-timestamp estimate, kept in
  a 16-sample window from which the minimum-RTT sample is taken as truth and
  smoothed with an EMA.
* **Device latency**: the receiver subtracts its own output latency
  (`kAudioDevicePropertyLatency` + safety offset + IO buffer + stream latency,
  27 ms on a typical built-in output) so `play_at_ns` is honoured at the
  speaker, not at the render callback.
* **Rate**: two Macs' crystals differ by ~±100 ppm, which is a lost or
  duplicated sample every few seconds. The ring's fill level drives a PI loop
  that trims a 4-tap Hermite resampler by at most **±200 ppm** (0.35 cent —
  inaudible). Only a level error past **±20 ms** causes a hard re-anchor.
* **Loss**: a gap in the play-out timeline is zero-filled and counted; a
  packet that turns up out of order still lands in its own slot and takes its
  loss count back; a packet whose time has already passed is dropped as late.

## Requirements

macOS 14 or newer. Building needs the Swift toolchain from the Xcode Command
Line Tools (`xcode-select --install`) — no Xcode project, no dependencies, no
Xcode-only frameworks.

## Install

```sh
swift build -c release
.build/release/synccast-receiver --install --name "Receiver A"
```

`--install` writes `~/Library/LaunchAgents/io.syncast.receiver.plist`
(`RunAtLoad`, `KeepAlive`, `ProcessType Interactive`) with the flags you passed
alongside it, then `launchctl bootout`s any previous copy and `bootstrap`s the
new one into `gui/<uid>`. It prints exactly what it did, plus the pairing
token. Keep the built binary where it is — the plist points at that path.

It must be a **user agent**, not a system daemon: opening an output device
needs a user audio session.

On macOS 15 and later the first run raises the **Local Network** permission
prompt. Approve it, or the Bonjour advertisement and the media socket stay
invisible to the sender (System Settings → Privacy & Security → Local Network).

## Pairing

On first run the daemon generates a 32-hex-character token, stores it 0600 in
`~/Library/Application Support/SyncCastReceiver/config.json`, and prints it to
the log. Print it again any time:

```sh
.build/release/synccast-receiver --print-token
```

Type it into SyncCast once, for this receiver; SyncCast persists it per
receiver. The Bonjour TXT record advertises only the first 8 characters, as a
hint for telling two receivers apart — the full token has to be sent in
`hello`. Wrong token, or a peer that is not on a private (RFC1918 /
link-local / loopback) address, and the connection is refused.

## Flags

| Flag | Meaning |
| --- | --- |
| `--device <uid\|name>` | Output device: exact CoreAudio UID, exact name, or a case-insensitive name substring. Default: the built-in speakers, falling back to the system default output. |
| `--name <friendly>` | Name advertised over Bonjour. Default `Receiver`. |
| `--port <n>` | TCP control port. Default `47100`; `0` takes an ephemeral port (Bonjour still finds it). The UDP media port is always ephemeral and is reported in `hello_ack`. |
| `--print-token` | Print the pairing token and exit. |
| `--selftest` | Run the offline self-test (below) and exit. |
| `--install` / `--uninstall` | Manage the LaunchAgent. |

List the UIDs of your output devices with any CoreAudio tool, or just pass a
substring of the name shown in System Settings → Sound.

## Self-test

```sh
.build/release/synccast-receiver --selftest
```

Synthesises 70 s of a stream — with injected loss, duplication and reordering,
and a device clock 100 ppm fast — and runs it through the **real** packet
parser, jitter buffer, clock loop and resampler with no network and no audio
hardware. It checks the loss/duplicate/late accounting, that there are no
underruns or clipping, that the buffer sits at its setpoint, that the trim
stays inside ±200 ppm and converges on the clock error, that the output level
is right, and that playout lands within a millisecond of `play_at_ns`. It
prints `SELFTEST PASS` and exits 0 when everything holds. It takes a few
seconds of CPU and works on a machine with no audio devices at all.

## Running it by hand

```sh
.build/release/synccast-receiver --name "Receiver A"
```

Logs go to `~/Library/Logs/SyncCastReceiver/receiver.log` (rotated at 5 MB
into `receiver.log.1`), and to the terminal as well when stderr is a TTY. Once
a second, while a stream is running, the daemon logs and sends the sender a
`stats` line: late, lost, underrun and clip counts, the buffer level in
milliseconds, and the current trim.

## Latency

`target_ms` comes from the sender (default 90 ms, useful range 30–300). What
you get end to end is roughly `target_ms` plus the sender's own capture and
ring latency. Below about 60 ms on Wi-Fi the buffer starts to run out during
ordinary interference; a wired LAN is comfortable at 40 ms. The counters tell
you which side of the line you are on: `underrun` must stay 0.

## Behaviour under load, sleep and faults

* Transient faults are retries, never exits: no output device yet, the device
  went away, the port is still in `TIME_WAIT`, the network dropped — all retry
  (every 2 s for the device) and the process stays alive for launchd.
* Sleep/wake invalidates bound sockets silently; a `NWPathMonitor` re-arms both
  channels when the path comes back.
* No `ping` for 5 s and the daemon stops playback and mutes itself.
* `SIGTERM` (what `launchctl bootout` sends) stops the audio unit cleanly.
  **The hardware volume is deliberately left where the sender set it** — the
  level belongs to the speaker the listener is using, and snapping it back on
  every restart would fight the sender's own state.

## Volume

A `gain` message carries the sender's master as linear amplitude plus a mute
flag. If the output device exposes a settable
`kAudioDevicePropertyVolumeScalar`, the level is applied in hardware: the
amplitude is converted to decibels and then to a scalar using the device's own
`VolumeRangeDecibels` / `VolumeDecibelsToScalar`, falling back to Apple's
measured dB-linear curve over [−63.5, 0] dB. Writing the amplitude straight
into the scalar would apply the taper twice and everything would be far too
quiet. Devices with no volume control (aggregates, most DisplayPort and HDMI
outputs) get software gain in the render path instead, with a per-block ramp so
a jump in the master does not click. `hello_ack.hw_volume` tells the sender
which of the two it got.

## Uninstall

```sh
.build/release/synccast-receiver --uninstall
```

Boots the agent out and removes the plist. The config (with your token) and the
logs are left alone; delete
`~/Library/Application Support/SyncCastReceiver` and
`~/Library/Logs/SyncCastReceiver` if you want them gone.

## Protocol

Discovery is Bonjour `_synccast-pcm._udp` with TXT `v=1`, `name`, `token`
(8-hex hint), `rate=48000`; the advertised port is the TCP control port.
Control is newline-delimited JSON over TCP (`hello`, `gain`, `latency`,
`ping`, `bye` in; `hello_ack`, `pong`, `stats`, `error` out). Media is UDP: a
24-byte little-endian header (`magic "SCPC"`, `stream_id`, `seq`,
`play_at_ns`, `frames`) followed by 240 frames of interleaved Int16 LE — 984
bytes per packet, one every 5 ms.

One optional extension to the v1 spec: a sender may include `prev_t4` in a
`ping` (its receive timestamp for the previous `pong`). With it the receiver
closes the NTP four-timestamp loop itself; without it it falls back to a
one-way minimum-delay estimate, which on a LAN biases playout by the minimum
one-way delay — a few hundred microseconds — and nothing else.

## Tests

```sh
swift test
```

Covers the packet header (including sequence wrap), the control-message codec
against the literal wire shapes, the NTP offset math with asymmetric delay,
jitter-buffer accounting under reordering and duplication, the PI loop's
convergence and its ±200 ppm clamp, the volume law's round trip, the peer
filter, the config store's permissions, and the self-test end to end.

## License

MIT — see [LICENSE](LICENSE).
