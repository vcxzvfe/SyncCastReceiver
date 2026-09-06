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
  inaudible). The level it holds is the one the timestamp anchor produced —
  `target − device latency − transit`, measured over a 3 s settle window —
  not the nominal `target − device latency`: transit is the network's, and a
  loop that chased the nominal figure would sit at its +200 ppm stop and drag
  playout late by one transit delay. Only a level error past **±20 ms** that
  persists causes a hard re-anchor, and every re-anchor (cold start, level
  error, starvation, target change) goes back through the timestamp mapping,
  so it lands on the schedule rather than at a fixed distance behind whatever
  burst arrived last.
* **Payload format**: `s16le` (the v1 wire format) or `f32le`, negotiated
  per stream — the sender asks in `hello`, the receiver echoes the format it
  will decode in `hello_ack`. Float32 carries the sender's mix untouched:
  the master level is applied on this side, so the signal on the wire is
  pre-volume and can legitimately exceed full scale (a hot programme, an EQ
  boost); Int16 had to clip it there. 3 Mbit/s on a LAN is nothing.
* **IO buffer**: `--io-buffer <frames>` (default 256, 5.3 ms) asks the
  output device for a smaller render quantum than macOS's default 512. Two
  blocks are the floor of every playout target and one block is part of the
  device latency, so this takes about 16 ms off the lowest usable target.
  `--io-buffer 0` leaves the device alone.
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

### The Application Firewall

If macOS's Application Firewall is on and this binary is not on its allow
list, **the link fails in a way that looks like it is working**. The kernel
completes the TCP handshake before the firewall adjudicates, so the sender's
connect succeeds and `nc -z` reports the port open — but the daemon never sees
a connection, never answers `hello`, and the sender sits waiting. On a Mac with
nobody at the keyboard the "do you want the application to accept incoming
network connections?" dialog is never answered, so an unsigned or ad-hoc-signed
build stays blocked indefinitely.

`--install` checks for this and prints what to do; ask at any time with:

```sh
.build/release/synccast-receiver --doctor
```

It reads `socketfilterfw --getglobalstate` and `--listapps` and reports whether
this binary will actually be reachable. It never runs `sudo` and never changes
a setting — if the binary needs allowing, it prints the two commands to run
yourself:

```sh
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "/absolute/path/to/synccast-receiver"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "/absolute/path/to/synccast-receiver"
```

Re-run them after rebuilding to a different path. If the firewall is set to
*block all incoming connections*, no per-application exception helps — turn
that option off in System Settings → Network → Firewall → Options.

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
| `--doctor` | Report whether the Application Firewall will let this binary accept connections, and print the commands to allow it. Read-only. |
| `--status` | Print what the running daemon last published: ports, device, hardware volume, current sender, last stats line. |
| `--install` / `--uninstall` | Manage the LaunchAgent. |

List the UIDs of your output devices with any CoreAudio tool, or just pass a
substring of the name shown in System Settings → Sound.

## Self-test

```sh
.build/release/synccast-receiver --selftest
```

Runs four simulated links through the **real** packet parser, jitter buffer,
clock loop and resampler, with no network and no audio hardware. The first two
are about the NETWORK; the last two are about the SENDER.

1. **Steady** — 70 s of a wired-LAN-shaped stream (one packet every 5 ms) with
   injected loss, duplication and reordering, and a device clock 100 ppm fast.
   It checks the loss/duplicate/late accounting, that there are no underruns
   or clipping, that the buffer sits at its setpoint, that the trim stays
   inside ±200 ppm and converges on the clock error, that the output level is
   right, and that playout lands within a millisecond of `play_at_ns`.
2. **Bursty** — 90 s of a Wi-Fi-shaped stream: packets delivered in bursts of
   six every 30 ms, plus a delivery stall of 80 ms about once a second. The
   contract is **zero hard re-anchors** after warm-up, with underruns budgeted
   against the stalls that were injected. Burst delivery empties the ring for
   a block at the end of most gaps; a receiver that treats that as starvation
   splices — and clicks — several times a second.
3. **Sender idles then resumes** — steady delivery, two seconds of nothing at
   all, then delivery again two seconds further along the sender's timeline.
   A programme that stops is silence, not starvation: once the pause is
   recognised no more underruns are counted, the resume is one silent
   re-anchor rather than a splice, and the level and alignment come back
   exactly where they were.
4. **Overlapping timeline** — a well-behaved stream with a second one
   interleaved into it, claiming slots the ring already holds and carrying
   different audio. Every one is counted as `overlap` and none of it reaches
   the DAC: same output level, same alignment, no splices. This is the shape
   of a real sender fault, heard as two copies of the music at once.

It prints `SELFTEST PASS` and exits 0 when everything holds. It takes a few
seconds of CPU and works on a machine with no audio devices at all.

## Checking on a running daemon

```sh
.build/release/synccast-receiver --status
```

The daemon republishes
`~/Library/Application Support/SyncCastReceiver/status.json` on every state
change and on its one-second stats tick; `--status` renders it. It says when
the file is stale, and when the pid that wrote it is gone — so a daemon that
died without cleaning up is reported as dead rather than described as if it
were still playing.

## Running it by hand

```sh
.build/release/synccast-receiver --name "Receiver A"
```

Logs go to `~/Library/Logs/SyncCastReceiver/receiver.log` (rotated at 5 MB
into `receiver.log.1`), and to the terminal as well when stderr is a TTY. Once
a second, while a stream is running, the daemon logs and sends the sender a
`stats` line: late, lost, underrun and clip counts, the buffer level in
milliseconds, the current trim, the number of hard re-anchors split by cause
(`reanchor_starved` / `reanchor_error`), the link's measured p95 arrival
jitter, the target it is actually running at, and the packets it had to refuse
(`overlap` / `far_future`). The log line adds `hold=` (the level the loop is
holding, or `settling` for the first seconds after an anchor), `extra=` (delay
this side adds beyond the sender's target, when it had to raise it) and
`lift=` (how far an anchor had to lift the cursor above the pure timestamp
mapping to keep a minimum fill — a steady non-zero value means the clock
offset estimate is biased).

Those last two are about the SENDER, not about the link. `overlap` counts
packets whose frames overlapped audio already buffered — a correct sender
cannot produce one, because every packet comes from a distinct span of its
capture ring, so a non-zero count means it is stamping more than one timeline.
`far_future` counts play times more than two seconds past the newest buffered
frame. Both are refused rather than written, and both get their own WARN line
(rate limited to one a second) saying which side the fault is on.

Every hard re-anchor also gets its own INFO line saying why it happened and
with what numbers (level error, ring fill, consecutive starved blocks), rate
limited to one per second. A re-anchor is an audible splice, so if the audio
clicks, that line says which of the two faults caused it.

## Latency

`target_ms` comes from the sender (default 90 ms, useful range 30–300). What
you get end to end is roughly `target_ms` plus the sender's own capture and
ring latency. Below about 60 ms on Wi-Fi the buffer starts to run out during
ordinary interference; a wired LAN is comfortable at 40 ms.

The receiver treats that number as a FLOOR it may raise, never a ceiling. It
measures how spread out packet arrivals actually are on this link (p95 minus
the best packet in the last few seconds, reported as `p95_jitter_ms`) and
raises the target to at least that plus two render blocks, capped at 300 ms.
A target below the spread cannot work — the buffer would be asked to hold
less audio than the network routinely withholds — so it is better to add the
latency than to click. The value in use is what `hello_ack.buffer_ms` and
`stats.target_ms` report, and a line in the log says when and why it was
raised.

The counters tell you which side of the line you are on. `underrun` counts
render blocks that ran dry: some are unavoidable on a link that stalls, and
they cost a few milliseconds of silence each. `reanchor_*` is the one to
watch — a re-anchor is a splice, and a healthy link has none.

## Wi-Fi and AWDL

If the receiver is on Wi-Fi and the stream stutters in a pattern — clean for
a while, then a burst of late packets — measure the link before touching any
audio setting: `ping -i 0.1 <router>` from the receiver Mac. Delays of
~100 ms recurring every 0.524 s (512 TU) are AWDL, the peer-to-peer Wi-Fi
behind AirDrop, Universal Control and Continuity: while `awdl0` is active the
radio leaves the channel for that long, which is a 20 % duty cycle of
blackouts and no playout target under ~150 ms survives it. `ifconfig awdl0 |
grep status` says whether it is active; macOS re-enables it on a login, an
AirDrop window or a nearby Mac's Universal Control, so
`sudo scripts/awdl-guard.sh install` puts a root LaunchDaemon in place that
keeps it down (and disables AirDrop / Universal Control on that Mac until
`uninstall`).

## Silence

A sender with nothing to play sends nothing. After half a second without a
packet the receiver treats the link as **idle** rather than starved: it
renders silence, stops counting underruns, leaves the clock loop alone and
does not re-anchor. The first packet back resets the stream and re-anchors
once, silently, primed to the target — so a paused programme costs no click on
resume, and the audio that comes back is not measured against a schedule that
stopped seconds ago.

The same reasoning applies for shorter gaps: a starvation splice is suppressed
on any render block that brought no new audio at all. Delivery has stopped, so
re-anchoring would land the cursor on the same empty ring having thrown away
loop state that was tracking the sender's clock correctly.

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
  every restart would fight the sender's own state. Hardware *mute* is the one
  exception: if the sender muted the device and then went away, the daemon
  releases the mute when it stops, because a shared output stuck on mute looks
  like broken hardware and playback has already stopped anyway.

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

### Holding the level against the rest of the machine

The output device belongs to the whole Mac, not to this daemon. While a stream
is active the daemon watches `kAudioDevicePropertyVolumeScalar` and
`kAudioDevicePropertyMute` on it, and if something else moves them — a
remote-desktop session muting the Mac on connect is the usual culprit — it
re-applies the sender's last `gain` within about 200 ms and logs one line. Its
own writes open a short suppression window so they are not mistaken for
somebody else's change, with a sweep just past the window's end to catch an
external change that landed inside it. Watching stops when the stream stops:
with no sender, the device is nobody else's business but the local user's.
None of this applies on the software-gain path, where nothing outside this
process can change the level.

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
