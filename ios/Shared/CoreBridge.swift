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
        let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        if let error = object?["error"] as? [String: Any] {
            throw TunnelError.message(error["message"] as? String ?? "Core call failed")
        }
        if let message = object?["result"] as? String, !message.isEmpty {
            throw TunnelError.message(message)
        }
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
