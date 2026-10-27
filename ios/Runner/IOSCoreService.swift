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
    private var vpnOptions: Data?
    private var recovery: TunnelSnapshot?
    private var localLease: CoreLease?
    private var initialized = false
    private var remote = false
    private var transitioning = false
    private var closed = false
    private var revision = 0
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
                            self?.statusChanged(refresh: true)
                        } else {
                            self?.suspendLocalCore()
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
                        if isTunnelActive { try await shutdownLocalCore() }
                        if manager?.connection.status == .connecting {
                            try await waitForConnection(connected: true)
                        } else if manager?.connection.status == .disconnecting {
                            try await waitForConnection(connected: false)
                        }
                        remote = isTunnelActive
                        if let snapshot = try? await Task.detached(priority: .utility, operation: {
                            try TunnelStorage.load()
                        }).value {
                            recovery = snapshot
                            initialization = snapshot.initialization
                            vpnOptions = snapshot.options
                        }
                        if !remote && localLease == nil {
                            localLease = try await CoreLease.acquire(directory: TunnelStorage.root())
                        }
                        initialized = true
                        startPolling()
                        result("")
                    } catch { result(error.localizedDescription) }
                }
            }
        case "syncState":
            gate.barrier { [self] done in
                Task { @MainActor in
                    defer { done() }
                    do {
                        guard let raw = call.arguments as? String,
                            let state = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                            let options = state["vpnOptions"] as? [String: Any]
                        else { throw TunnelError.message("Missing iOS VPN options") }
                        let data = try JSONSerialization.data(withJSONObject: options)
                        if var snapshot = recovery, snapshot.options != data {
                            snapshot.options = data
                            try await persist(snapshot)
                        }
                        vpnOptions = data
                        result("")
                    } catch { result(error.localizedDescription) }
                }
            }
        case "start", "stop":
            revision = (call.arguments as? NSNumber)?.intValue ?? revision + 1
            let requestedRevision = revision
            let running = call.method == "start"
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
                        try await reconcileTunnel()
                        if running { try await start(requestedRevision) } else { try await stop() }
                        result(requestedRevision == revision)
                    } catch { fail(error, result) }
                }
            }
        case "getRunTime":
            gate.request { [self] done in
                result(runTime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0)
                done()
            }
        case "shutdown":
            closed = true
            revision += 1
            stopPolling()
            gate.barrier { [self] done in
                Task { @MainActor in
                    defer { done() }
                    do {
                        try await disconnect()
                        try await shutdownLocalCore()
                        result(true)
                    } catch { fail(error, result) }
                }
            }
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func invoke(_ raw: String, result: @escaping FlutterResult) {
        if remote != isTunnelActive
            || (!remote && localLease == nil && UIApplication.shared.applicationState != .background)
        {
            statusChanged()
        }
        let operation: CoreRequestGate.Operation = { [self] done in
            guard !closed, remote || localLease != nil else {
                fail(TunnelError.message("Core service is unavailable"), result)
                done()
                return
            }
            rememberSubscriptionIntent(raw)
            let complete: (Data) -> Void = { data in
                Task { @MainActor in
                    do {
                        try await self.remember(raw, response: data)
                        result(FlutterStandardTypedData(bytes: data))
                    } catch { self.fail(error, result) }
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
        let method = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["method"] as? String
        if ["initClash", "setupConfig", "updateConfig", "changeProxy"].contains(method ?? "") {
            gate.barrier(operation)
        } else {
            gate.request(operation)
        }
    }

    private func remember(_ raw: String, response: Data) async throws {
        guard let call = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            let method = call["method"] as? String,
            ["initClash", "setupConfig", "updateConfig", "changeProxy"].contains(method),
            let result = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
            result["error"] == nil || result["error"] is NSNull
        else { return }
        guard let arguments = call["arguments"], !(arguments is NSNull),
            let data = try? JSONSerialization.data(withJSONObject: arguments)
        else { return }
        switch method {
        case "initClash" where result["result"] as? Bool == true:
            initialization = data
        case "setupConfig" where (result["result"] as? String ?? "").isEmpty:
            guard let initialization, let vpnOptions else {
                throw TunnelError.message("Missing iOS configuration recovery parameters")
            }
            let snapshot = try await Task.detached(priority: .utility) {
                try TunnelSnapshot.capture(initialization: initialization, setup: data, options: vpnOptions)
            }.value
            try await persist(snapshot)
        case "updateConfig" where (result["result"] as? String ?? "").isEmpty:
            guard var snapshot = recovery, let patch = arguments as? [String: Any] else { return }
            var update = try snapshot.update.map {
                try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:]
            } ?? [:]
            update.merge(patch.filter { !($0.value is NSNull) }) { _, newest in newest }
            snapshot.update = try JSONSerialization.data(withJSONObject: update)
            try await persist(snapshot)
        case "changeProxy":
            guard var snapshot = recovery, let change = arguments as? [String: Any],
                let answer = result["result"] as? [String: Any],
                (answer["message"] as? String ?? "").isEmpty,
                let group = change["group-name"] as? String,
                let proxy = change["proxy-name"] as? String,
                var parameters = try JSONSerialization.jsonObject(with: snapshot.setup) as? [String: Any]
            else { return }
            var selected = parameters["selected-map"] as? [String: String] ?? [:]
            selected[group] = proxy
            parameters["selected-map"] = selected
            snapshot.setup = try JSONSerialization.data(withJSONObject: parameters)
            try await persist(snapshot)
        default: break
        }
    }

    private func persist(_ snapshot: TunnelSnapshot) async throws {
        try await Task.detached(priority: .utility) { try TunnelStorage.save(snapshot) }.value
        recovery = snapshot
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
        guard var snapshot = recovery, let vpnOptions else {
            throw TunnelError.message("Apply a profile before starting the VPN")
        }
        let options = try JSONSerialization.jsonObject(with: vpnOptions) as? [String: Any] ?? [:]
        guard options["enable"] as? Bool ?? true else {
            try await CoreBridge.checked("startListener")
            localRunTime = Date()
            return
        }
        snapshot.options = vpnOptions
        try await persist(snapshot)
        try await shutdownLocalCore()
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
        localRunTime = nil
        if remote || isTunnelActive {
            try await disconnect()
            if UIApplication.shared.applicationState != .background { try await restoreLocal() }
        } else if localLease != nil {
            try await CoreBridge.checked("stopListener")
        }
    }

    private func restoreLocal() async throws {
        guard localLease == nil, UIApplication.shared.applicationState != .background else { return }
        localLease = try await CoreLease.acquire(directory: TunnelStorage.root())
        remote = false
        do {
            if let recovery {
                try await recovery.restoreCore()
            } else if let initialization {
                try await CoreBridge.checked(
                    "initClash", arguments: JSONSerialization.jsonObject(with: initialization))
            }
            if localRunTime != nil { try await CoreBridge.checked("startListener") }
            try await restoreSubscriptions()
        } catch {
            try await shutdownLocalCore()
            throw error
        }
    }

    private func shutdownLocalCore() async throws {
        guard localLease != nil else { return }
        try await CoreBridge.checked("shutdown")
        localLease = nil
    }

    private var runTime: Date? {
        remote ? manager?.connection.connectedDate : localRunTime
    }

    private func reconcileTunnel() async throws {
        if isTunnelActive {
            try await shutdownLocalCore()
            if manager?.connection.status == .disconnecting {
                try await waitForConnection(connected: false)
            } else {
                do { try await waitForConnection(connected: true) } catch {
                    if isTunnelActive { throw error }
                }
                if isTunnelActive {
                    remote = true
                    localRunTime = nil
                    try await restoreSubscriptions()
                    return
                }
            }
        }
        if remote { localRunTime = nil }
        remote = false
        try await restoreLocal()
    }

    private func suspendLocalCore() {
        stopPolling()
        guard initialized, !closed else { return }
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Release local Core") {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        gate.barrier { [self] done in
            Task { @MainActor in
                defer {
                    if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
                    done()
                }
                guard UIApplication.shared.applicationState == .background else { return }
                do { try await shutdownLocalCore() } catch {
                    NSLog("FlClash: could not release the local Core: %@", error.localizedDescription)
                }
            }
        }
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
        // startTunnel returns before the app's copy of the status leaves .disconnected,
        // so a stopped tunnel only counts once it was seen starting or the grace ran out.
        let grace = Date().addingTimeInterval(3)
        var started = false
        while Date() < deadline {
            let status = manager?.connection.status ?? .invalid
            if connected && status == .connected { return }
            if !connected && [.disconnected, .invalid].contains(status) { return }
            if [.connecting, .reasserting].contains(status) { started = true }
            if connected && (started || Date() >= grace) && [.disconnected, .invalid].contains(status) {
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
        guard !polling, !closed, !transitioning, remote || localLease != nil,
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

    private func statusChanged(refresh: Bool = false) {
        guard initialized, !closed else { return }
        let observedRevision = revision
        stopPolling()
        if !isTunnelActive {
            for reply in Array(pendingReplies.values) {
                reply(.failure(TunnelError.message("The VPN extension disconnected")))
            }
        }
        gate.barrier { [self] done in
            Task { @MainActor in
                defer {
                    transitioning = false
                    done()
                    startPolling()
                }
                guard !closed else { return }
                transitioning = true
                stopPolling()
                do {
                    if refresh { manager = try await loadManager() }
                    try await reconcileTunnel()
                    let options = remote ? try await send(["command": "options"]) : vpnOptions
                    guard observedRevision == revision else { return }
                    channel.invokeMethod("vpnState", arguments: [
                        "revision": observedRevision,
                        "startTime": runTime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0,
                        "vpnOptions": options.map { String(decoding: $0, as: UTF8.self) } ?? NSNull(),
                    ])
                } catch {
                    NSLog("FlClash: could not reconcile the VPN Core: %@", error.localizedDescription)
                }
            }
        }
    }

    private func fail(_ error: Error, _ result: FlutterResult) {
        result(FlutterError(code: "ios_core", message: error.localizedDescription, details: nil))
    }
}
