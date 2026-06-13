import Darwin
import Foundation

/// Helpers for diagnosing wireless-pairing failures caused by the Mac and the
/// phone sitting on different IP subnets (the #1 real-world cause of adb's
/// cryptic "protocol fault" during pairing).
enum NetworkInfo {
    /// This Mac's non-loopback IPv4 addresses (e.g. ["192.168.1.218"]).
    static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if r == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty, ip != "0.0.0.0" { addresses.append(ip) }
            }
        }
        return addresses
    }

    /// "192.168.1.180" or "192.168.1.180:41571" → "192.168.1" (its /24 prefix).
    static func subnet24(of hostOrEndpoint: String) -> String? {
        let host = hostOrEndpoint.split(separator: ":").first.map(String.init) ?? hostOrEndpoint
        let octets = host.split(separator: ".")
        guard octets.count == 4, octets.allSatisfy({ Int($0) != nil }) else { return nil }
        return octets.prefix(3).joined(separator: ".")
    }

    /// If the target's /24 differs from every local address, return the pair of
    /// subnets for a helpful message; nil if they match or can't be determined.
    static func subnetMismatch(target endpoint: String) -> (mac: String, phone: String)? {
        guard let phoneSubnet = subnet24(of: endpoint) else { return nil }
        let localSubnets = localIPv4Addresses().compactMap { subnet24(of: $0) }
        guard !localSubnets.isEmpty else { return nil }
        if localSubnets.contains(phoneSubnet) { return nil }
        return (mac: localSubnets.first! + ".x", phone: phoneSubnet + ".x")
    }

    /// Turn a raw pairing failure into a network-aware, actionable message.
    static func pairingErrorMessage(endpoint: String, underlying: String) -> String {
        if let m = subnetMismatch(target: endpoint) {
            return """
            Your Mac (\(m.mac)) and phone (\(m.phone)) are on different Wi-Fi networks, \
            so they can't reach each other to pair. Connect both to the same network — \
            if you use a mesh router (e.g. Deco) behind another router, putting it in \
            Access Point mode collapses everything onto one network.
            """
        }
        return underlying
    }
}
