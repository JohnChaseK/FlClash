import Darwin
import FlClashCore
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let requests = DispatchQueue(label: "com.follow.clash.tunnel.requests")
    private var generation = 0
    private var lifecycle: Task<Void, Never>?
    private var coreLease: CoreLease?
    private var activeOptions: Data?

    override func startTunnel(
        options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void
    ) {
        Task { @MainActor in
            generation += 1
            let current = generation
            let previous = lifecycle
            let operation = Task { @MainActor in
                await previous?.value
                guard current == generation else {
                    completionHandler(CancellationError())
                    return
                }
                await start(current: current, completionHandler: completionHandler)
            }
            lifecycle = operation
        }
    }

    @MainActor
    private func start(current: Int, completionHandler: @escaping (Error?) -> Void) async {
        do {
            coreLease = try await CoreLease.acquire(directory: TunnelStorage.root())
            guard generation == current else { throw CancellationError() }
            let snapshot = try TunnelStorage.load()
            let vpn = try JSONSerialization.jsonObject(with: snapshot.options) as? [String: Any] ?? [:]
            try await snapshot.restoreCore()
            guard generation == current else { throw CancellationError() }
            let settings = try TunnelNetworkSettings.make(vpn)
            try await setTunnelNetworkSettings(settings)
            guard generation == current else { throw CancellationError() }
            let descriptor = try tunnelDescriptor()
            let addresses =
                (vpn["ipv6"] as? Bool ?? false)
                ? "198.18.0.1/30,fdfe:dcba:9876::1/126" : "198.18.0.1/30"
            let tunOptions = try JSONSerialization.data(withJSONObject: [
                "mtu": TunnelNetworkSettings.mtu(for: vpn),
                "congestion-controller": vpn["congestionController"] as? String ?? "",
            ])
            let dns = (vpn["dnsHijacking"] as? Bool ?? true) ? "0.0.0.0,::" : "198.18.0.2"
            guard
                AppleStartTun(
                    descriptor, vpn["stack"] as? String ?? "mixed", addresses, dns,
                    String(decoding: tunOptions, as: UTF8.self)
                )
            else { throw TunnelError.message("The Core could not open the packet tunnel") }
            activeOptions = snapshot.options
            completionHandler(nil)
        } catch {
            AppleStopTun()
            await shutdownCore()
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason, completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            generation += 1
            let previous = lifecycle
            lifecycle = Task { @MainActor in
                await previous?.value
                AppleSuspendEvents()
                AppleStopTun()
                await shutdownCore()
                completionHandler()
            }
        }
    }

    @MainActor
    private func shutdownCore() async {
        guard coreLease != nil else { return }
        do {
            try await CoreBridge.checked("shutdown")
            coreLease = nil
            activeOptions = nil
        } catch {
            NSLog("FlClash: could not shut down the tunnel Core: %@", error.localizedDescription)
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        requests.async {
            do {
                let request = try JSONSerialization.jsonObject(with: messageData) as? [String: Any]
                switch request?["command"] as? String {
                case "invoke":
                    guard let name = request?["reference"] as? String else {
                        throw TunnelError.message("Missing Core request")
                    }
                    let data = try TunnelStorage.readMessage(Data(name.utf8))
                    CoreBridge.invoke(String(decoding: data, as: UTF8.self)) { result in
                        completionHandler?(try? TunnelStorage.writeMessage(result))
                    }
                case "events":
                    DispatchQueue.global(qos: .utility).async {
                        let events = ApplePollEvent() ?? Data()
                        completionHandler?(try? TunnelStorage.writeMessage(events))
                    }
                case "suspendEvents":
                    AppleSuspendEvents()
                    completionHandler?(Data())
                case "options":
                    Task { @MainActor in completionHandler?(self.activeOptions) }
                default:
                    throw TunnelError.message("Unknown tunnel command")
                }
            } catch {
                completionHandler?(nil)
            }
        }
    }

    private func tunnelDescriptor() throws -> Int32 {
        let raw = packetFlow.value(forKeyPath: "socket.fileDescriptor")
        var preferred: Int32?
        if let value = raw as? Int32 {
            preferred = value
        } else if let value = raw as? Int {
            preferred = Int32(exactly: value)
        } else if let value = raw as? NSNumber {
            preferred = value.int32Value
        } else {
            preferred = nil
        }
        return try TunnelDescriptor.duplicate(
            preferred: preferred,
            address: "198.18.0.1"
        )
    }
}
