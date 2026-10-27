import Darwin
import NetworkExtension

enum TunnelNetworkSettings {
    static func mtu(for options: [String: Any]) -> Int {
        let requested = options["mtu"] as? Int ?? 0
        return requested > 0 ? min(max(requested, 1280), 1500) : 1500
    }

    static func make(_ options: [String: Any]) throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: mtu(for: options))
        let routes = options["routeAddress"] as? [String] ?? []
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = try routes.filter { !$0.contains(":") }.map(ipv4Route)
        if routes.isEmpty { ipv4.includedRoutes = [.default()] }
        // DNS must enter the tunnel even when custom routes exclude its subnet.
        ipv4.includedRoutes?.append(
            NEIPv4Route(
                destinationAddress: "198.18.0.2", subnetMask: "255.255.255.255"
            ))
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
        if options["ipv6"] as? Bool ?? false {
            ipv6.includedRoutes = try routes.filter { $0.contains(":") }.map(ipv6Route)
            if routes.isEmpty { ipv6.includedRoutes = [.default()] }
        } else {
            // Capture disabled IPv6 so it cannot bypass the VPN on the physical interface.
            ipv6.includedRoutes = [.default()]
        }
        settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: ["198.18.0.2"])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        if options["systemProxy"] as? Bool ?? false {
            let port = options["port"] as? Int ?? 7890
            let proxy = NEProxySettings()
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            proxy.httpServer = NEProxyServer(address: "127.0.0.1", port: port)
            proxy.httpsServer = NEProxyServer(address: "127.0.0.1", port: port)
            proxy.exceptionList = options["bypassDomain"] as? [String] ?? []
            proxy.matchDomains = [""]
            settings.proxySettings = proxy
        }
        return settings
    }

    private static func prefix(_ value: String, maximum: Int) throws -> (String, Int) {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]), (0...maximum).contains(bits) else {
            throw TunnelError.message("Invalid VPN route: \(value)")
        }
        return (String(parts[0]), bits)
    }

    private static func ipv4Route(_ value: String) throws -> NEIPv4Route {
        let (address, bits) = try prefix(value, maximum: 32)
        var parsed = in_addr()
        guard inet_pton(AF_INET, address, &parsed) == 1 else {
            throw TunnelError.message("Invalid IPv4 route: \(value)")
        }
        let mask: UInt32 = bits == 0 ? 0 : UInt32.max << (32 - bits)
        let dotted = [24, 16, 8, 0].map { String((mask >> $0) & 255) }.joined(separator: ".")
        return NEIPv4Route(destinationAddress: address, subnetMask: dotted)
    }

    private static func ipv6Route(_ value: String) throws -> NEIPv6Route {
        let (address, bits) = try prefix(value, maximum: 128)
        var parsed = in6_addr()
        guard inet_pton(AF_INET6, address, &parsed) == 1 else {
            throw TunnelError.message("Invalid IPv6 route: \(value)")
        }
        return NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: bits))
    }
}
