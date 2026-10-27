import Darwin
import Foundation

enum TunnelDescriptor {
    static func duplicate(preferred: Int32?, address: String) throws -> Int32 {
        guard let target = interfaceName(for: address), target.hasPrefix("utun") else {
            throw TunnelError.message("The packet tunnel interface is unavailable")
        }
        if let preferred, socketInterfaceName(preferred) == target {
            return try duplicate(preferred)
        }
        // Only duplicate this tunnel's socket; other utun interfaces can coexist.
        for descriptor in 0..<getdtablesize() where socketInterfaceName(descriptor) == target {
            return try duplicate(descriptor)
        }
        throw TunnelError.message("iOS did not expose a descriptor for \(target)")
    }

    private static func duplicate(_ descriptor: Int32) throws -> Int32 {
        let owned = dup(descriptor)
        guard owned >= 0 else {
            throw TunnelError.message("Could not duplicate the tunnel descriptor")
        }
        return owned
    }

    private static func socketInterfaceName(_ descriptor: Int32) -> String? {
        guard descriptor >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var length = socklen_t(buffer.count)
        guard getsockopt(descriptor, 2, 2, &buffer, &length) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func interfaceName(for address: String) -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var current: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let socketAddress = entry.pointee.ifa_addr,
                Int32(socketAddress.pointee.sa_family) == AF_INET
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    socketAddress, socklen_t(socketAddress.pointee.sa_len), &buffer,
                    socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
                ) == 0,
                String(cString: buffer) == address
            else { continue }
            return String(cString: entry.pointee.ifa_name)
        }
        return nil
    }
}
