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

    public init(options: Options, config: ReceiverConfig, log: Log) {
        self.options = options
        self.config = config
        self.log = log
        self.engine = PlayoutEngine()
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
            audioSocket.close()
            engine.stopStream()
            output?.stop()
            output = nil
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
            log.info("control channel listening on TCP port \(port), advertising \(WireFormat.bonjourServiceType)")
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
            engine.setTargetLatency(milliseconds: Double(latency.targetMs))
            log.info("target latency set to \(latency.targetMs) ms")
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
                                  bufferMs: Int(engine.targetLatencyMilliseconds.rounded()))
        controlServer?.send(.helloAck(ack))
        log.info("stream \(hello.streamID) from \"\(hello.name)\" at \(peer): "
                 + "udp \(audioSocket.boundPort), target \(ack.bufferMs) ms, "
                 + "device latency \(String(format: "%.1f", output.outputLatencyMilliseconds)) ms")
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
            let status = volume.setScalar(deviceScalar.isFinite ? deviceScalar : scalar)
            if status != noErr { log.warn("hardware volume write failed with OSStatus \(status)") }
            engine.setSoftwareGain(1.0)
            if volume.hasMute {
                volume.setMuted(muted)
                appliedHardwareMute = muted
                engine.setMuted(false)
            } else {
                engine.setMuted(muted)
            }
        case .software:
            engine.setSoftwareGain(Double(plan.softwareAmplitude ?? 0))
            engine.setMuted(muted)
        }
    }

    private func stopStreaming(reason: String) {
        guard streaming else { return }
        streaming = false
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
    }

    private func emitStats() {
        guard streaming else { return }
        let snapshot = engine.snapshot
        let message = StatsMessage(late: snapshot.counters.late,
                                   lost: snapshot.counters.lost,
                                   underrun: snapshot.counters.underrun,
                                   bufferMs: (snapshot.levelMilliseconds * 100).rounded() / 100,
                                   ratio: (snapshot.ratio * 1e9).rounded() / 1e9,
                                   clip: snapshot.clip)
        controlServer?.send(.stats(message))
        log.debug("stats late=\(message.late) lost=\(message.lost) underrun=\(message.underrun) "
                  + "buffer=\(String(format: "%.1f", message.bufferMs))ms "
                  + "trim=\(String(format: "%+.1f", (message.ratio - 1) * 1e6))ppm "
                  + "clip=\(message.clip) reanchor=\(snapshot.reanchors)")
    }
}
