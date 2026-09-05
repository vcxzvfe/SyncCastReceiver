import Foundation
import Network
import CoreAudio

/// Ties the pieces together: Bonjour + control channel + media socket +
/// CoreAudio output, with the retry behaviour launchd expects.
///
/// Design rule for everything in here: a transient fault is a retry, never an
/// exit. Under launchd a non-zero exit is a crash loop with backoff, and a
/// receiver that gives up because a display went to sleep is useless.
public final class ReceiverDaemon: @unchecked Sendable {

    public struct Options: Sendable {
        public var name: String
        public var deviceQuery: String?
        public var port: UInt16
        public var defaultTargetMilliseconds: Double

        public init(name: String, deviceQuery: String?, port: UInt16,
                    defaultTargetMilliseconds: Double = 90) {
            self.name = name
            self.deviceQuery = deviceQuery
            self.port = port
            self.defaultTargetMilliseconds = defaultTargetMilliseconds
        }
    }

    private enum Constants {
        static let pingTimeoutSeconds: Double = 5
        static let statsIntervalSeconds: Double = 1
        static let deviceRetrySeconds: Double = 2
        static let listenerRetrySeconds: Double = 2
        /// How often the "still no output device" warning may repeat.
        static let deviceWarningIntervalSeconds: Double = 60
        /// How often the "something else changed the level" line may repeat
        /// while the same fight is still going on.
        static let externalChangeLogIntervalSeconds: Double = 5
        /// Smallest change to the effective target worth a splice.
        static let targetChangeThresholdMs: Double = 5
        /// How long the effective target must hold still between changes.
        /// The jitter measurement moves continuously; re-targeting on every
        /// tick would be a splice per second.
        static let targetChangeIntervalSeconds: Double = 10
        /// How often the "raised the target" line may repeat.
        static let targetClampLogIntervalSeconds: Double = 60
    }

    private let options: Options
    private let config: ReceiverConfig
    private let log: Log
    private let clock = MachClock()
    private let engine: PlayoutEngine
    private let queue = DispatchQueue(label: "io.syncast.receiver.daemon")

    private var audioSocket: AudioSocket!
    private var controlServer: ControlServer?
    private var output: AUHALOutput?
    private var volume: HardwareVolumeControl?
    private var device: AudioOutputDevice?
    private var pathMonitor: NWPathMonitor?

    private var offsetEstimator = ClockOffsetEstimator()
    private var pendingExchange: (t1: UInt64, t2: UInt64, t3: UInt64)?
    private var lastPingNanos: UInt64?
    private var connectedPeer: String?
    private var streaming = false
    private var lastPathSatisfied = true
    private var appliedHardwareMute = false
    private var lastDeviceWarningNanos: UInt64?

    private var statsTimer: DispatchSourceTimer?
    private var maintenanceTimer: DispatchSourceTimer?

    // Level re-assertion. `desired*` is what the sender last asked for on the
    // hardware path; `volumeSuppressedUntilNanos` is the window in which a
    // reported change is our own write coming back.
    private var volumeObserver: DeviceVolumeObserver?
    private var desiredScalar: Float?
    private var desiredMuted = false
    private var volumeSuppressedUntilNanos: UInt64?
    private var volumeSweepScheduled = false
    private var volumeVerifyScheduled = false
    /// When the "something else changed the level" line was last written.
    /// nil once a sweep finds the device where we want it, so a NEW external
    /// change is always reported.
    private var lastExternalChangeLogNanos: UInt64?

    private let statusFile: StatusFile
    private let startedAtEpoch = Date().timeIntervalSince1970
    private var lastStatsLine: String?
    /// What the sender asked for, and what we settled on after measuring the
    /// link. They differ when the link is too jittery for the request.
    private var requestedTargetMs: Double
    private var effectiveTargetMs: Double
    private var lastTargetChangeNanos: UInt64?
    private var lastTargetClampLogNanos: UInt64?
    /// Sequence number of the last re-anchor already written to the log.
    private var loggedReanchorSequence: Int = 0
    private var loggedReanchorTotal: Int = 0
    private var lastControlPort: UInt16 = 0
    private var statusWriteFailureLogged = false

    public init(options: Options, config: ReceiverConfig, log: Log,
                statusFile: StatusFile? = nil) {
        self.options = options
        self.config = config
        self.log = log
        self.statusFile = statusFile ?? StatusFile()
        self.engine = PlayoutEngine()
        self.requestedTargetMs = options.defaultTargetMilliseconds
        self.effectiveTargetMs = options.defaultTargetMilliseconds
        self.engine.setTargetLatency(milliseconds: options.defaultTargetMilliseconds)
        self.audioSocket = AudioSocket(engine: engine) { [weak self] message in
            self?.log.warn("media socket: \(message)")
        }
    }

    // MARK: - lifecycle

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.log.info("SyncCastReceiver starting as \"\(self.options.name)\" (token hint \(self.config.tokenHint))")
            self.openMediaSocket()
            self.startOutputIfNeeded()
            self.startListener()
            self.startTimers()
            self.startPathMonitor()
            self.publishStatus()
        }
    }

    /// Clean shutdown for SIGTERM. The hardware volume is deliberately LEFT
    /// where the sender put it: the level is a property of the speaker the
    /// user is listening to, and snapping it back on every restart would
    /// fight the sender's own state.
    public func shutdown() {
        queue.sync {
            log.info("shutting down")
            statsTimer?.cancel(); statsTimer = nil
            maintenanceTimer?.cancel(); maintenanceTimer = nil
            pathMonitor?.cancel(); pathMonitor = nil
            controlServer?.stop(); controlServer = nil
            volumeObserver?.stop(); volumeObserver = nil
            audioSocket.close()
            engine.stopStream()
            output?.stop()
            output = nil
            // Removed rather than left behind: a stale file that says
            // "streaming" would send the next `--status` reader down the
            // wrong path entirely.
            statusFile.remove()
        }
        log.flush()
    }

    // MARK: - subsystems

    private func openMediaSocket() {
        do {
            let port = try audioSocket.open(port: 0)
            log.info("media socket listening on UDP port \(port)")
        } catch {
            log.error("could not open the media socket: \(error); retrying")
        }
    }

    private func startListener() {
        let advertisement = ControlServer.Advertisement(name: options.name, tokenHint: config.tokenHint)
        let server = ControlServer(port: options.port, advertisement: advertisement) { [weak self] event in
            self?.queue.async { self?.handle(event) }
        }
        controlServer = server
        do { try server.start() } catch { log.error("could not start the control listener: \(error)") }
    }

    private func restartListener(reason: String) {
        log.warn("restarting the control listener: \(reason)")
        controlServer?.stop()
        controlServer = nil
        queue.asyncAfter(deadline: .now() + Constants.listenerRetrySeconds) { [weak self] in
            guard let self, self.controlServer == nil else { return }
            self.startListener()
        }
    }

    @discardableResult
    private func startOutputIfNeeded() -> Bool {
        if let output, output.isRunning, let device, AudioDevices.isAlive(device.id) { return true }
        output?.stop()
        output = nil
        // The listeners belong to the OLD device id; keeping them would leave
        // us re-asserting a level on a device nobody is listening to.
        volumeObserver?.stop()
        volumeObserver = nil
        do {
            let resolved = try AudioDevices.resolve(query: options.deviceQuery)
            let newOutput = AUHALOutput(device: resolved, engine: engine)
            try newOutput.start()
            device = resolved
            output = newOutput
            lastDeviceWarningNanos = nil
            volume = HardwareVolumeControl(deviceID: resolved.id)
            log.info("output device \"\(resolved.name)\" [\(resolved.uid)] "
                     + "rate \(Int(resolved.nominalSampleRate)) Hz, "
                     + "latency \(String(format: "%.1f", newOutput.outputLatencyMilliseconds)) ms, "
                     + "hardware volume \(volume?.hasVolume == true ? "yes" : "no")")
            return true
        } catch {
            // The retry runs every two seconds forever; saying so every two
            // seconds would be the only thing in the log.
            let now = clock.nowNanos()
            let quiet = lastDeviceWarningNanos.map {
                Double(now &- $0) / 1_000_000_000 < Constants.deviceWarningIntervalSeconds
            } ?? false
            if !quiet {
                lastDeviceWarningNanos = now
                log.warn("output device unavailable (\(error)); retrying every "
                         + "\(Int(Constants.deviceRetrySeconds)) s")
            }
            return false
        }
    }

    private func startTimers() {
        let stats = DispatchSource.makeTimerSource(queue: queue)
        stats.schedule(deadline: .now() + Constants.statsIntervalSeconds,
                       repeating: Constants.statsIntervalSeconds)
        stats.setEventHandler { [weak self] in self?.emitStats() }
        stats.resume()
        statsTimer = stats

        let maintenance = DispatchSource.makeTimerSource(queue: queue)
        maintenance.schedule(deadline: .now() + Constants.deviceRetrySeconds,
                             repeating: Constants.deviceRetrySeconds)
        maintenance.setEventHandler { [weak self] in self?.maintain() }
        maintenance.resume()
        maintenanceTimer = maintenance
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.queue.async { self?.handlePathChange(path) }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// Sleep/wake and Wi-Fi changes invalidate bound sockets silently; re-arm
    /// both channels when the network comes back.
    private func handlePathChange(_ path: NWPath) {
        let satisfied = path.status == .satisfied
        defer { lastPathSatisfied = satisfied }
        guard satisfied, !lastPathSatisfied else { return }
        log.info("network path came back; re-arming sockets")
        audioSocket.close()
        openMediaSocket()
        if let peer = connectedPeer { audioSocket.setExpectedPeer(peer) }
        restartListener(reason: "network path change")
    }

    private func maintain() {
        startOutputIfNeeded()
        guard streaming, let last = lastPingNanos else { return }
        let idleNanos = clock.nowNanos() &- last
        if Double(idleNanos) / 1_000_000_000 > Constants.pingTimeoutSeconds {
            log.warn("no ping for \(Int(Constants.pingTimeoutSeconds)) s; stopping and muting")
            stopStreaming(reason: "ping timeout")
        }
    }

    // MARK: - control channel

    private func handle(_ event: ControlServer.Event) {
        switch event {
        case .listening(let port):
            lastControlPort = port
            log.info("control channel listening on TCP port \(port), advertising \(WireFormat.bonjourServiceType)")
            publishStatus()
        case .connected(let peer):
            log.info("sender connected from \(peer)")
        case .rejected(let peer, let reason):
            log.warn("rejected \(peer): \(reason)")
        case .disconnected(let peer):
            log.info("sender \(peer) disconnected")
            stopStreaming(reason: "sender disconnected")
            connectedPeer = nil
            audioSocket.setExpectedPeer(nil)
            audioSocket.setExpectedStreamID(nil)
            publishStatus()
        case .failed(let message):
            restartListener(reason: message)
        case .message(let message, let peer):
            handle(message: message, peer: peer)
        }
    }

    private func handle(message: ControlMessage, peer: String) {
        switch message {
        case .hello(let hello):
            handleHello(hello, peer: peer)
        case .gain(let gain):
            applyGain(linear: gain.linear, muted: gain.muted)
        case .latency(let latency):
            requestedTargetMs = Double(latency.targetMs)
            lastTargetChangeNanos = nil
            let effective = applyTargetLatency(force: true)
            if effective > requestedTargetMs + 0.5 {
                log.info("target latency set to \(latency.targetMs) ms, raised to "
                         + "\(Int(effective.rounded())) ms by the measured link jitter")
            } else {
                log.info("target latency set to \(latency.targetMs) ms")
            }
        case .ping(let ping):
            handlePing(ping)
        case .bye:
            log.info("sender said goodbye")
            stopStreaming(reason: "bye")
        case .helloAck, .pong, .stats, .error:
            log.warn("ignoring a receiver-to-sender message arriving from \(peer)")
        }
    }

    private func handleHello(_ hello: HelloMessage, peer: String) {
        guard config.matches(token: hello.token) else {
            log.warn("refusing \(peer): wrong token")
            controlServer?.disconnectPeer(reason: "invalid token")
            return
        }
        guard hello.rate == Int(WireFormat.sampleRate),
              hello.channels == WireFormat.channelCount,
              hello.framesPerPacket == WireFormat.framesPerPacket else {
            let detail = "unsupported format \(hello.rate) Hz / \(hello.channels) ch / \(hello.framesPerPacket) frames"
            log.warn("refusing \(peer): \(detail)")
            controlServer?.disconnectPeer(reason: detail)
            return
        }
        guard startOutputIfNeeded(), let device, let output else {
            controlServer?.disconnectPeer(reason: "no output device available")
            return
        }
        if audioSocket.boundPort == 0 { openMediaSocket() }

        connectedPeer = peer
        // A new stream is a new link measurement: the previous sender's
        // jitter says nothing about this one's.
        engine.arrivalTracker.reset()
        requestedTargetMs = options.defaultTargetMilliseconds
        effectiveTargetMs = requestedTargetMs
        lastTargetChangeNanos = nil
        lastTargetClampLogNanos = nil
        loggedReanchorSequence = 0
        loggedReanchorTotal = 0
        engine.setTargetLatency(milliseconds: requestedTargetMs)
        offsetEstimator.reset()
        pendingExchange = nil
        lastPingNanos = clock.nowNanos()
        engine.clearClockOffset()
        engine.resetCounters()
        audioSocket.setExpectedPeer(peer)
        audioSocket.setExpectedStreamID(hello.streamID)
        engine.setMuted(false)
        engine.startStream()
        streaming = true

        let ack = HelloAckMessage(udpPort: Int(audioSocket.boundPort),
                                  device: device.name,
                                  deviceUID: device.uid,
                                  hwVolume: volume?.hasVolume ?? false,
                                  // The EFFECTIVE target, not the requested
                                  // one: the sender aligns its local legs on
                                  // this number, so it has to be the truth.
                                  bufferMs: Int(engine.targetLatencyMilliseconds.rounded()))
        controlServer?.send(.helloAck(ack))
        log.info("stream \(hello.streamID) from \"\(hello.name)\" at \(peer): "
                 + "udp \(audioSocket.boundPort), target \(ack.bufferMs) ms, "
                 + "device latency \(String(format: "%.1f", output.outputLatencyMilliseconds)) ms")
        startVolumeObserverIfNeeded()
        publishStatus()
    }

    private func handlePing(_ ping: PingMessage) {
        let t2 = clock.nowNanos()
        lastPingNanos = t2
        // Close the previous exchange if the sender told us when its pong
        // arrived; otherwise fall back to the one-way estimate.
        if let t4 = ping.prevT4, let previous = pendingExchange {
            offsetEstimator.addRoundTrip(t1: previous.t1, t2: previous.t2, t3: previous.t3, t4: t4)
        } else {
            offsetEstimator.addOneWay(t1: ping.t1, t2: t2)
        }
        let t3 = clock.nowNanos()
        pendingExchange = (t1: ping.t1, t2: t2, t3: t3)
        controlServer?.send(.pong(PongMessage(t1: ping.t1, t2: t2, t3: t3)))
        if let offset = offsetEstimator.offsetNanos { engine.setClockOffset(nanos: offset) }
    }

    private func applyGain(linear: Double, muted: Bool) {
        let plan = VolumePlan.plan(linear: linear, muted: muted, law: volume?.law)
        switch plan.backend {
        case .hardware:
            guard let volume, let scalar = plan.hardwareScalar else { return }
            // Ask the driver for the conversion when it offers one.
            let deviceScalar = volume.scalar(forAmplitude: Float(min(max(linear, 0), 1)))
            let wanted = deviceScalar.isFinite ? deviceScalar : scalar
            desiredScalar = wanted
            desiredMuted = volume.hasMute ? muted : false
            writeHardwareLevel(volume: volume, scalar: wanted, muted: muted)
            engine.setSoftwareGain(1.0)
            engine.setMuted(volume.hasMute ? false : muted)
            startVolumeObserverIfNeeded()
        case .software:
            // Nothing external can move a software gain, so there is nothing
            // to watch and nothing to re-assert.
            desiredScalar = nil
            desiredMuted = false
            engine.setSoftwareGain(Double(plan.softwareAmplitude ?? 0))
            engine.setMuted(muted)
        }
    }

    /// The one place that writes the device's level, so the suppression
    /// window is opened on every write and cannot be forgotten at a call
    /// site.
    private func writeHardwareLevel(volume: HardwareVolumeControl, scalar: Float, muted: Bool) {
        volumeSuppressedUntilNanos = VolumeReassertionPolicy.suppressionDeadline(
            nowNanos: clock.nowNanos())
        let status = volume.setScalar(scalar)
        if status != noErr { log.warn("hardware volume write failed with OSStatus \(status)") }
        if volume.hasMute {
            volume.setMuted(muted)
            appliedHardwareMute = muted
        }
        scheduleVolumeVerification()
    }

    private func stopStreaming(reason: String) {
        guard streaming else { return }
        streaming = false
        // Stop defending a level nobody is driving any more: with no sender,
        // the device belongs entirely to whoever else is using this Mac.
        volumeObserver?.stop()
        volumeObserver = nil
        desiredScalar = nil
        volumeSuppressedUntilNanos = nil
        lastExternalChangeLogNanos = nil
        engine.setMuted(true)
        engine.stopStream()
        // The LEVEL stays where the sender put it — that is the level the
        // listener is hearing everything else at. Hardware MUTE is different:
        // it is a switch on a device the local user shares, and leaving it
        // engaged after we stopped would look like broken hardware. We are
        // already silent because the stream is stopped.
        if appliedHardwareMute, let volume, volume.hasMute {
            volume.setMuted(false)
            appliedHardwareMute = false
            log.info("released the device's hardware mute (the volume level is left as the sender set it)")
        }
        engine.clearClockOffset()
        audioSocket.setExpectedStreamID(nil)
        lastPingNanos = nil
        pendingExchange = nil
        log.info("playback stopped (\(reason))")
        publishStatus()
    }

    private func emitStats() {
        guard streaming else { return }
        applyTargetLatency(force: false)
        let snapshot = engine.snapshot
        let message = StatsMessage(late: snapshot.counters.late,
                                   lost: snapshot.counters.lost,
                                   underrun: snapshot.counters.underrun,
                                   bufferMs: (snapshot.levelMilliseconds * 100).rounded() / 100,
                                   ratio: (snapshot.ratio * 1e9).rounded() / 1e9,
                                   clip: snapshot.clip,
                                   reanchorStarved: snapshot.reanchorsByReason[.starved] ?? 0,
                                   reanchorError: snapshot.reanchorsByReason[.error] ?? 0,
                                   p95JitterMs: snapshot.p95JitterMilliseconds
                                       .map { ($0 * 100).rounded() / 100 },
                                   targetMs: (engine.targetLatencyMilliseconds * 10).rounded() / 10)
        controlServer?.send(.stats(message))
        let jitter = message.p95JitterMs.map { String(format: "%.1fms", $0) } ?? "-"
        let line = "late=\(message.late) lost=\(message.lost) underrun=\(message.underrun) "
            + "buffer=\(String(format: "%.1f", message.bufferMs))ms "
            + "trim=\(String(format: "%+.1f", (message.ratio - 1) * 1e6))ppm "
            + "clip=\(message.clip) reanchor=\(snapshot.reanchors)"
            + "(starved=\(message.reanchorStarved) error=\(message.reanchorError)) "
            + "p95jitter=\(jitter) target=\(String(format: "%.0f", message.targetMs))ms"
        lastStatsLine = line
        log.debug("stats \(line)")
        logReanchorIfNew(snapshot)
        publishStatus()
    }

    /// One INFO line per re-anchor, at most one per stats tick.
    ///
    /// A splice is audible, so the reason it happened belongs in the log at a
    /// level the user actually reads — but a link that is spliced repeatedly
    /// would otherwise write a line per event, hundreds a minute. The 1 Hz
    /// tick is the rate limit, and the count of what it swallowed is on the
    /// line so nothing is hidden.
    private func logReanchorIfNew(_ snapshot: PlayoutEngine.Snapshot) {
        guard let event = snapshot.lastReanchor, event.sequence != loggedReanchorSequence else {
            loggedReanchorTotal = snapshot.reanchors
            return
        }
        let swallowed = max(0, snapshot.reanchors - loggedReanchorTotal - 1)
        loggedReanchorSequence = event.sequence
        loggedReanchorTotal = snapshot.reanchors
        let extra = swallowed > 0 ? " (+\(swallowed) more since the last line)" : ""
        log.info("re-anchored the playout cursor: \(event.reason.rawValue) — "
                 + "level error \(String(format: "%+.1f", event.errorMilliseconds)) ms, "
                 + "ring fill \(String(format: "%.1f", event.fillMilliseconds)) ms, "
                 + "\(event.starvedBlocks) starved block(s)\(extra)")
    }

    /// Raise the playout target to what the measured link needs, if it needs
    /// more than the sender asked for.
    ///
    /// Changing it splices, so it is deliberately sticky: only a change worth
    /// at least `targetChangeThresholdMs`, and at most one every
    /// `targetChangeIntervalSeconds`.
    @discardableResult
    private func applyTargetLatency(force: Bool) -> Double {
        let blockFrames = output?.renderBlockFrames ?? WireFormat.framesPerPacket
        let wanted = TargetLatencyPolicy.effectiveMilliseconds(
            requestedMs: requestedTargetMs,
            p95JitterMs: engine.snapshot.p95JitterMilliseconds,
            blockFrames: blockFrames,
            sampleRate: engine.sampleRate)
        let now = clock.nowNanos()
        if !force {
            guard abs(wanted - effectiveTargetMs) >= Constants.targetChangeThresholdMs else {
                return effectiveTargetMs
            }
            let settled = lastTargetChangeNanos.map {
                Double(now &- $0) / 1_000_000_000 >= Constants.targetChangeIntervalSeconds
            } ?? true
            guard settled else { return effectiveTargetMs }
        }
        effectiveTargetMs = wanted
        lastTargetChangeNanos = now
        engine.setTargetLatency(milliseconds: wanted)
        if wanted > requestedTargetMs + 0.5 {
            let quiet = lastTargetClampLogNanos.map {
                Double(now &- $0) / 1_000_000_000 < Constants.targetClampLogIntervalSeconds
            } ?? false
            if !quiet {
                lastTargetClampLogNanos = now
                let jitter = engine.snapshot.p95JitterMilliseconds ?? 0
                log.info("raised the playout target from \(Int(requestedTargetMs.rounded())) ms to "
                         + "\(Int(wanted.rounded())) ms: this link's p95 arrival jitter is "
                         + "\(String(format: "%.1f", jitter)) ms and the buffer has to cover it")
            }
        }
        return wanted
    }

    // MARK: - level re-assertion

    /// Watch the device's level whenever the sender's master is being carried
    /// in hardware. Only then: on the software path nothing outside this
    /// process can change the gain, so there is nothing to defend.
    private func startVolumeObserverIfNeeded() {
        guard streaming, desiredScalar != nil, let device, let volume, volume.hasVolume else { return }
        if let existing = volumeObserver, existing.deviceID == device.id { return }
        volumeObserver?.stop()
        let observer = DeviceVolumeObserver(deviceID: device.id, queue: queue) { [weak self] _ in
            self?.scheduleVolumeSweep()
        }
        observer.start()
        guard observer.isObserving else {
            volumeObserver = nil
            return
        }
        volumeObserver = observer
        log.info("watching the output device's volume and mute; the sender's level "
                 + "will be re-applied if something else changes it")
    }

    /// Coalesce a burst of property notifications (a slider drag is many)
    /// into one comparison, and act on it fast — the whole path from an
    /// external change to the level being back where the sender put it stays
    /// inside about 200 ms.
    private func scheduleVolumeSweep() {
        guard !volumeSweepScheduled else { return }
        volumeSweepScheduled = true
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(VolumeReassertionPolicy.coalesceDelayNanos))
        ) { [weak self] in
            self?.volumeSweepScheduled = false
            self?.reassertLevelIfChanged()
        }
    }

    /// The safety net after our OWN write: an external change that lands
    /// inside the suppression window is (correctly) ignored at the time and
    /// produces no further notification, so without a sweep just past the
    /// window's end it would stick.
    private func scheduleVolumeVerification() {
        guard !volumeVerifyScheduled else { return }
        volumeVerifyScheduled = true
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(VolumeReassertionPolicy.verifyDelayNanos))
        ) { [weak self] in
            self?.volumeVerifyScheduled = false
            self?.reassertLevelIfChanged()
        }
    }

    private func reassertLevelIfChanged() {
        guard streaming, let volume, let desired = desiredScalar else { return }
        let now = clock.nowNanos()
        let observedScalar = volume.currentScalar() ?? .nan
        let scalarDecision = VolumeReassertionPolicy.decideScalar(
            observed: observedScalar,
            desired: desired,
            nowNanos: now,
            suppressedUntilNanos: volumeSuppressedUntilNanos)
        var muteDecision = VolumeReassertionDecision.matches
        if volume.hasMute, let observedMute = volume.currentMuted() {
            muteDecision = VolumeReassertionPolicy.decideMute(
                observed: observedMute,
                desired: desiredMuted,
                nowNanos: now,
                suppressedUntilNanos: volumeSuppressedUntilNanos)
        }
        guard scalarDecision == .reassert || muteDecision == .reassert else {
            // Back where it should be: the next external change is a new
            // event and gets its own line.
            if scalarDecision == .matches && muteDecision == .matches {
                lastExternalChangeLogNanos = nil
            }
            return
        }
        // One line per external change, not per write. Something that keeps
        // re-muting the Mac (a remote-desktop session reconnecting in a loop)
        // must not turn the log into a per-second stream.
        let quiet = lastExternalChangeLogNanos.map {
            Double(now &- $0) / 1_000_000_000 < Constants.externalChangeLogIntervalSeconds
        } ?? false
        if !quiet {
            lastExternalChangeLogNanos = now
            log.info("something else changed the output device "
                     + "(volume \(String(format: "%.3f", observedScalar)) vs "
                     + "\(String(format: "%.3f", desired))"
                     + (volume.hasMute ? ", mute \(volume.currentMuted() ?? false) vs \(desiredMuted)" : "")
                     + "); re-applying the sender's level")
        }
        writeHardwareLevel(volume: volume, scalar: desired, muted: desiredMuted)
    }

    // MARK: - status file

    /// Publish what `--status` reads. Cheap (a small atomic write), called on
    /// every state change and on the 1 Hz stats tick.
    private func publishStatus() {
        let status = ReceiverStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            name: options.name,
            startedAtEpoch: startedAtEpoch,
            updatedAtEpoch: Date().timeIntervalSince1970,
            controlPort: lastControlPort,
            udpPort: audioSocket.boundPort,
            deviceName: device?.name,
            deviceUID: device?.uid,
            hardwareVolume: volume?.hasVolume ?? false,
            streaming: streaming,
            peer: connectedPeer,
            lastStats: lastStatsLine,
            logPath: log.path)
        if let error = statusFile.write(status), !statusWriteFailureLogged {
            // Once only: an unwritable support directory is a real problem
            // but not one worth a line per second.
            statusWriteFailureLogged = true
            log.warn("could not publish the status file: \(error)")
        }
    }
}
