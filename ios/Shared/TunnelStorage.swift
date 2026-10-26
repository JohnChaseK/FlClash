import Foundation

struct TunnelSnapshot: Codable {
    let initialization: Data
    let setup: Data
    let options: Data
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

    static func save(_ snapshot: TunnelSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(
            to: root().appendingPathComponent("tunnel.json"), options: .atomic
        )
    }

    static func load() throws -> TunnelSnapshot {
        try JSONDecoder().decode(
            TunnelSnapshot.self, from: Data(contentsOf: root().appendingPathComponent("tunnel.json"))
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
