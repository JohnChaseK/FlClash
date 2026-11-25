import FlClashCore
import Foundation

final class CoreReply: NSObject, AppleResultHandlerProtocol {
    private let completion: (Data) -> Void

    init(_ completion: @escaping (Data) -> Void) {
        self.completion = completion
    }

    func onResult(_ data: Data?) throws {
        completion(data ?? Data())
    }
}

enum CoreBridge {
    static func invoke(_ raw: String, completion: @escaping (Data) -> Void) {
        AppleInvokeMethod(raw, CoreReply(completion))
    }

    static func call(_ method: String, arguments: Any? = nil) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: [
            "method": method, "arguments": arguments ?? NSNull(),
        ])
        return await withCheckedContinuation { continuation in
            invoke(String(decoding: data, as: UTF8.self)) {
                continuation.resume(returning: $0)
            }
        }
    }

    static func checked(_ method: String, arguments: Any? = nil) async throws {
        let response = try await call(method, arguments: arguments)
        if let message = try failure(object(from: response, deleteSpill: true)) {
            throw TunnelError.message(message)
        }
    }

    static func shutdown() {
        AppleShutdown()
    }

    static func object(from data: Data, deleteSpill: Bool = false) throws -> [String: Any] {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TunnelError.message("Core returned an unreadable response")
        }
        if let file = object["file"] as? String {
            object = try spilledObject(file, delete: deleteSpill)
        }
        return object
    }

    static func failure(_ object: [String: Any]) -> String? {
        guard let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? "Core call failed"
    }

    private static func spilledObject(_ path: String, delete: Bool) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "json",
            url.deletingLastPathComponent().lastPathComponent == "responses"
        else {
            throw TunnelError.message("Core answered with a file outside its spill directory")
        }
        defer {
            if delete { try? FileManager.default.removeItem(at: url) }
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TunnelError.message("Core wrote an unreadable spilled response")
        }
        return object
    }
}

enum TunnelError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
