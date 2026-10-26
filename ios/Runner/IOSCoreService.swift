import FlClashCore
import Flutter
import NetworkExtension
import UIKit

@MainActor
final class IOSCoreService: NSObject {
    private let channel: FlutterMethodChannel
    private let gate = CoreRequestGate()
    private var manager: NETunnelProviderManager?
    private var initialization: Data?
    private var setup: Data?
    private var vpnOptions: Data?
    private var remote = false
    private var transitioning = false
    private var closed = false
    private var revision = 0
    private var requestedRunning = false
    private var localRunTime: Date?
    private var routeWatch = false
    private var logsEnabled = false
    private var polling = false
    private var pollGeneration = 0
    private var pendingReplies: [UUID: (Result<Data, Error>) -> Void] = [:]
    private var observers: [NSObjectProtocol] = []

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.follow.clash/service", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [self] call, result in handle(call, result: result) }
        let core = FlutterMethodChannel(name: "com.follow.clash/core", binaryMessenger: messenger)
        core.setMethodCallHandler { [self] call, result in
            guard call.method == "invokeMethod", let raw = call.arguments as? String else {
                result(FlutterMethodNotImplemented)
                return
            }
            invoke(raw, result: result)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification]
        {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] notification in
                    Task { @MainActor in
                        if notification.name == UIApplication.didBecomeActiveNotification {
                            self?.startPolling()
                        } else {
                            self?.stopPolling()
                        }
                    }
                })
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.statusChanged() } })
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getSharedDirectory":
            do { result(try TunnelStorage.root().path) } catch { fail(error, result) }
        case "init":
            gate.barrier { [self] done in
                Task { @MainActor in
                    defer { done() }
                    do {
                        closed = false
                        try TunnelStorage.pruneAbandonedMessages()
                        manager = try await loadManager()
                        if manager?.connection.status == .connecting {
                            try await waitForConnection(connected: true)
                        } else if manager?.connection.status == .disconnecting {
                            try await waitForConnection(connected: false)
                        }
                        remote = isTunnelActive
                        if let snapshot = try? TunnelStorage.load() {
                            initialization = snapshot.initialization
                            setup = snapshot.setup
                            vpnOptions = snapshot.options
                        }
                        startPolling()
                        result("")
                    } catch { result(error.localizedDescription) }
                }
            }
        case "syncState":
            do {
                guard let raw = call.arguments as? String,
                    let state = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                    let options = state["vpnOptions"] as? [String: Any]
                else {
                    throw TunnelError.message("Missing iOS VPN options")
                }
                vpnOptions = try JSONSerialization.data(withJSONObject: options)
                if let latest = state["setupParams"] as? [String: Any], let setup,
                    var applied = try JSONSerialization.jsonObject(with: setup) as? [String: Any]
                {
                    applied.merge(latest) { _, newest in newest }
                    self.setup = try JSONSerialization.data(withJSONObject: applied)
                }
                result("")
            } catch { result(error.localizedDescription) }
        case "start", "stop":
            revision = (call.arguments as? NSNumber)?.intValue ?? revision + 1
            requestedRunning = call.method == "start"
            let requestedRevision = revision
            let running = requestedRunning
            gate.barrier { [self] done in
                Task { @MainActor in
                    defer { done() }
                    guard requestedRevision == revision, !closed else {
                        result(false)
                        return
                    }
                    transitioning = true
                    stopPolling()
                    defer {
                        transitioning = false
                        startPolling()
                    }
                    do {
                        if running { try await start(requestedRevision) } else { try await stop() }
                        result(requestedRevision == revision)
                    } catch { fail(error, result) }
                }
            }
        case "getRunTime":
            let date = remote ? manager?.connection.connectedDate : localRunTime
            result(date.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0)
        case "shutdown":
            closed = true
            revision += 1
            requestedRunning = false
            stopPolling()
            gate.barrier { [self] done in
                Task { @MainActor in
                    defer { done() }
                    do {
                        try await disconnect()
                        try await CoreBridge.checked("shutdown")
                        result(true)
                    } catch { fail(error, result) }
                }
            }
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func invoke(_ raw: String, result: @escaping FlutterResult) {
        gate.request { [self] done in
            guard !closed else {
                fail(TunnelError.message("Core service is closed"), result)
                done()
                return
            }
            rememberSubscriptionIntent(raw)
            let complete: (Data) -> Void = { data in
                Task { @MainActor in
                    self.remember(raw, response: data)
                    result(FlutterStandardTypedData(bytes: data))
                    done()
                }
            }
            if remote {
                do {
                    let reference = try TunnelStorage.writeMessage(Data(raw.utf8))
                    send(["command": "invoke", "reference": String(decoding: reference, as: UTF8.self)]) {
                        response in
                        TunnelStorage.removeMessage(reference)
                        do { complete(try TunnelStorage.readMessage(response.get())) } catch {
                            self.fail(error, result)
                            done()
                        }
                    }
                } catch {
                    fail(error, result)
                    done()
                }
            } else {
                CoreBridge.invoke(raw, completion: complete)
            }
        }
    }

    private func remember(_ raw: String, response: Data) {
        guard let call = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            let method = call["method"] as? String,
            ["initClash", "setupConfig"].contains(method),
            let result = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
            result["error"] == nil
        else { return }
        guard let arguments = call["arguments"], !(arguments is NSNull),
            let data = try? JSONSerialization.data(withJSONObject: arguments)
        else { return }
        switch call["method"] as? String {
        case "initClash": initialization = data
        case "setupConfig" where (result["result"] as? String ?? "").isEmpty: setup = data
        default: break
        }
    }

    private func rememberSubscriptionIntent(_ raw: String) {
        guard let call = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return
        }
        switch call["method"] as? String {
        case "watchRoute": routeWatch = call["arguments"] as? Bool ?? false
        case "startLog": logsEnabled = true
        case "stopLog": logsEnabled = false
        default: break
        }
    }

    private func start(_ requestedRevision: Int) async throws {
        guard !remote else { return }
        guard let initialization, let setup, let vpnOptions else {
            throw TunnelError.message("Apply a profile before starting the VPN")
        }
        let options = try JSONSerialization.jsonObject(with: vpnOptions) as? [String: Any] ?? [:]
        guard options["enable"] as? Bool ?? true else {
            try await CoreBridge.checked("startListener")
            localRunTime = Date()
            return
        }
        try TunnelStorage.save(
            TunnelSnapshot(initialization: initialization, setup: setup, options: vpnOptions))
        try await CoreBridge.checked("shutdown")
        do {
            let manager = try await configuredManager()
            guard requestedRevision == revision, !closed else { throw CancellationError() }
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw TunnelError.message("The VPN session is unavailable")
            }
            try session.startTunnel(options: nil)
            try await waitForConnection(connected: true)
            guard requestedRevision == revision, !closed else {
                try await disconnect()
                throw CancellationError()
            }
            remote = true
            localRunTime = nil
            try await restoreSubscriptions()
        } catch {
            // A timed-out start must be disconnected before the app reopens Core files.
            try await disconnect()
            try await restoreLocal()
            throw error
        }
    }

    private func stop() async throws {
        if remote || isTunnelActive {
            try await disconnect()
            try await restoreLocal()
        } else {
            try await CoreBridge.checked("stopListener")
        }
        localRunTime = nil
    }

    private func restoreLocal() async throws {
        remote = false
        if let initialization {
            try await CoreBridge.checked(
                "initClash", arguments: JSONSerialization.jsonObject(with: initialization))
        }
        if let setup {
            try await CoreBridge.checked("setupConfig", arguments: JSONSerialization.jsonObject(with: setup))
        }
        try await restoreSubscriptions()
    }

    private var isTunnelActive: Bool {
        guard let status = manager?.connection.status else { return false }
        return [.connected, .connecting, .reasserting, .disconnecting].contains(status)
    }

    private func loadManager() async throws -> NETunnelProviderManager? {
        let identifier = Bundle.main.bundleIdentifier! + ".PacketTunnel"
        return try await NETunnelProviderManager.loadAllFromPreferences().first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
        }
    }

    private func configuredManager() async throws -> NETunnelProviderManager {
        let target = manager ?? NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = Bundle.main.bundleIdentifier! + ".PacketTunnel"
        configuration.serverAddress = "FlClash"
        target.protocolConfiguration = configuration
        target.localizedDescription = "FlClash"
        target.isEnabled = true
        try await target.saveToPreferences()
        try await target.loadFromPreferences()
        manager = target
        return target
    }

    private func disconnect() async throws {
        guard isTunnelActive else {
            remote = false
            return
        }
        manager?.connection.stopVPNTunnel()
        try await waitForConnection(connected: false)
        remote = false
    }

    private func waitForConnection(connected: Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let status = manager?.connection.status ?? .invalid
            if connected && status == .connected { return }
            if !connected && [.disconnected, .invalid].contains(status) { return }
            if connected && [.disconnected, .invalid].contains(status) {
                throw TunnelError.message(
                    "The VPN extension stopped before connecting; check the device console")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TunnelError.message("Timed out waiting for the VPN extension")
    }

    private func remoteCall(_ raw: String) async throws -> Data {
        let reference = try TunnelStorage.writeMessage(Data(raw.utf8))
        defer { TunnelStorage.removeMessage(reference) }
        let response = try await send([
            "command": "invoke", "reference": String(decoding: reference, as: UTF8.self),
        ])
        return try TunnelStorage.readMessage(response)
    }

    private func restoreSubscriptions() async throws {
        let methods: [(String, Any?)] = [
            (logsEnabled ? "startLog" : "stopLog", nil), ("watchRoute", routeWatch),
        ]
        for (method, arguments) in methods {
            if remote {
                let data = try JSONSerialization.data(withJSONObject: [
                    "method": method, "arguments": arguments ?? NSNull(),
                ])
                _ = try await remoteCall(String(decoding: data, as: UTF8.self))
            } else {
                try await CoreBridge.checked(method, arguments: arguments)
            }
        }
    }

    private func send(_ request: [String: Any]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            send(request) { continuation.resume(with: $0) }
        }
    }

    private func send(_ request: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            completion(.failure(TunnelError.message("The VPN session is unavailable")))
            return
        }
        let identifier = UUID()
        var reply: ((Result<Data, Error>) -> Void)? = completion
        var timeout: DispatchWorkItem?
        let finish: (Result<Data, Error>) -> Void = { [self] result in
            guard let completion = reply else {
                if case .success(let reference) = result { TunnelStorage.removeMessage(reference) }
                return
            }
            reply = nil
            timeout?.cancel()
            timeout = nil
            pendingReplies.removeValue(forKey: identifier)
            completion(result)
        }
        pendingReplies[identifier] = finish
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            try session.sendProviderMessage(data) { response in
                DispatchQueue.main.async {
                    if let response {
                        finish(.success(response))
                    } else {
                        finish(.failure(TunnelError.message("The VPN extension did not answer")))
                    }
                }
            }
            let work = DispatchWorkItem {
                finish(.failure(TunnelError.message("The VPN extension request timed out")))
            }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: work)
        } catch { finish(.failure(error)) }
    }

    private func startPolling() {
        guard !polling, !closed, !transitioning,
            UIApplication.shared.applicationState != .background
        else { return }
        polling = true
        pollGeneration += 1
        let generation = pollGeneration
        gate.request { [self] done in
            guard !remote, routeWatch, !closed else {
                done()
                return
            }
            CoreBridge.invoke("{\"method\":\"watchRoute\",\"arguments\":true}") { _ in
                Task { @MainActor in done() }
            }
        }
        Task { @MainActor in
            while polling && generation == pollGeneration {
                do {
                    let events: Data
                    if remote {
                        events = try TunnelStorage.readMessage(await send(["command": "events"]))
                    } else {
                        events = await Task.detached(priority: .utility) { ApplePollEvent() ?? Data() }.value
                    }
                    guard polling, generation == pollGeneration else { return }
                    if !events.isEmpty {
                        channel.invokeMethod("event", arguments: FlutterStandardTypedData(bytes: events))
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func stopPolling() {
        polling = false
        pollGeneration += 1
        AppleSuspendEvents()
    }

    private func statusChanged() {
        guard remote, !isTunnelActive, !transitioning, !closed else { return }
        transitioning = true
        let stoppedRevision = revision
        stopPolling()
        for reply in Array(pendingReplies.values) {
            reply(.failure(TunnelError.message("The VPN extension disconnected")))
        }
        gate.barrier { [self] done in
            Task { @MainActor in
                defer {
                    transitioning = false
                    done()
                    startPolling()
                }
                guard remote, !isTunnelActive else { return }
                do { try await restoreLocal() } catch {
                    NSLog("FlClash: could not restore the local Core: %@", error.localizedDescription)
                }
                if requestedRunning { channel.invokeMethod("stopped", arguments: stoppedRevision) }
            }
        }
    }

    private func fail(_ error: Error, _ result: FlutterResult) {
        result(FlutterError(code: "ios_core", message: error.localizedDescription, details: nil))
    }
}
