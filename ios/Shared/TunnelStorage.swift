import Darwin
import Foundation

struct TunnelSnapshot: Codable {
    let initialization: Data
    var setup: Data
    var options: Data
    var configuration: Data?
    var update: Data?

    static func capture(initialization: Data, setup: Data, options: Data) throws -> TunnelSnapshot {
        guard var parameters = try JSONSerialization.jsonObject(with: setup) as? [String: Any] else {
            throw TunnelError.message("Invalid Core setup parameters")
        }
        // Recovery uses the resolved YAML even if its source profile is edited or removed.
        parameters.removeValue(forKey: "base")
        return TunnelSnapshot(
            initialization: initialization,
            setup: try JSONSerialization.data(withJSONObject: parameters), options: options,
            configuration: try Data(contentsOf: configurationURL(initialization)))
    }

    func restoreCore() async throws {
        try restoreConfiguration()
        try await CoreBridge.checked(
            "initClash", arguments: JSONSerialization.jsonObject(with: initialization))
        try await CoreBridge.checked("setupConfig", arguments: JSONSerialization.jsonObject(with: setup))
        if let update {
            try await CoreBridge.checked("updateConfig", arguments: JSONSerialization.jsonObject(with: update))
        }
    }

    func restoreConfiguration() throws {
        if let configuration {
            try configuration.write(to: Self.configurationURL(initialization), options: .atomic)
        }
    }

    private static func configurationURL(_ initialization: Data) throws -> URL {
        guard let parameters = try JSONSerialization.jsonObject(with: initialization) as? [String: Any],
            let directory = parameters["home-dir"] as? String
        else { throw TunnelError.message("Missing Core home directory") }
        return URL(fileURLWithPath: directory).appendingPathComponent("config.yaml")
    }
}

final class CoreLease {
    private let handle: FileHandle

    private init(_ handle: FileHandle) {
        self.handle = handle
    }

    deinit { handle.closeFile() }

    static func acquire(directory: URL, timeout: TimeInterval = 25) async throws -> CoreLease {
        let path = directory.appendingPathComponent("core.lock").path
        if !FileManager.default.fileExists(atPath: path),
            !FileManager.default.createFile(atPath: path, contents: nil)
        {
            throw TunnelError.message("Could not create the Core ownership lock")
        }
        guard let handle = FileHandle(forUpdatingAtPath: path) else {
            throw TunnelError.message("Could not open the Core ownership lock")
        }
        let lease = CoreLease(handle)
        let deadline = Date().addingTimeInterval(timeout)
        while flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                throw TunnelError.message("Another Core still owns the shared directory")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
        return lease
    }
}

enum TunnelStorage {
    static func root() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FlClashAppGroup") as? String,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group
            )
        else {
            throw TunnelError.message("The App Group entitlement is missing or invalid")
        }
        let directory = container.appendingPathComponent("Library/Application Support/FlClash")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func save(_ snapshot: TunnelSnapshot, directory: URL? = nil) throws {
        try JSONEncoder().encode(snapshot).write(
            to: (directory ?? root()).appendingPathComponent("tunnel.json"), options: .atomic
        )
    }

    static func load(directory: URL? = nil) throws -> TunnelSnapshot {
        try JSONDecoder().decode(
            TunnelSnapshot.self,
            from: Data(contentsOf: (directory ?? root()).appendingPathComponent("tunnel.json"))
        )
    }

    static func writeMessage(_ data: Data) throws -> Data {
        let name = UUID().uuidString
        let directory = try messageDirectory()
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return Data(name.utf8)
    }

    static func readMessage(_ reference: Data) throws -> Data {
        let name = String(decoding: reference, as: UTF8.self)
        guard UUID(uuidString: name) != nil else {
            throw TunnelError.message("Invalid tunnel message reference")
        }
        let url = try messageDirectory().appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 64 * 1024 * 1024 else {
            throw TunnelError.message("Tunnel message exceeds 64 MiB")
        }
        return try Data(contentsOf: url)
    }

    static func removeMessage(_ reference: Data) {
        _ = try? readMessage(reference)
    }

    static func pruneAbandonedMessages() throws {
        let oldest = Date().addingTimeInterval(-24 * 60 * 60)
        for name in ["ipc", "responses"] {
            let directory = try root().appendingPathComponent(name)
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
                )
            else { continue }
            for file in files {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
                if let modified = values.contentModificationDate, modified < oldest {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private static func messageDirectory() throws -> URL {
        let directory = try root().appendingPathComponent("ipc")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
