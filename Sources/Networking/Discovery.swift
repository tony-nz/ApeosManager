import Foundation

struct DiscoveredPrinter: Identifiable, Hashable, Sendable {
    var host: String
    var name: String
    var model: String
    var serial: String
    var status: String
    var requiresAuth: Bool
    var id: String { host }

    var subtitle: String {
        var parts: [String] = []
        if !serial.isEmpty { parts.append("S/N \(serial)") }
        if requiresAuth { parts.append("sign-in required") }
        if !status.isEmpty { parts.append(status.replacingOccurrences(of: "_", with: " ").capitalized) }
        return parts.joined(separator: " · ")
    }
}

/// Sweeps the local subnet for Apeos devices.
///
/// `/home/api/device-status` is served by every tested model regardless of whether
/// the rest of `/home/api` requires an administrator session, which makes it a
/// dependable probe. `/home/api/about` is then tried for identity; a 403 there means
/// the device is real but locked down, which is recorded rather than treated as a miss.
final class PrinterDiscovery: NSObject, URLSessionDelegate, @unchecked Sendable {

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2.5
        cfg.timeoutIntervalForResource = 3
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// Every Apeos ships a self-signed certificate. Discovery only reads a public
    /// status endpoint and never transmits credentials, so trust is granted for the
    /// probe; per-printer trust for real traffic is handled in ApeosClient.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Local subnet

    /// The /24 prefix of the first active non-loopback IPv4 interface, e.g. "192.0.2".
    static func localPrefix() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var best: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }

            let ip = String(cString: host)
            let name = String(cString: ptr.pointee.ifa_name)
            let octets = ip.split(separator: ".")
            guard octets.count == 4 else { continue }
            let prefix = octets.prefix(3).joined(separator: ".")
            // Prefer a physical interface over utun/bridge tunnels.
            if name.hasPrefix("en") { return prefix }
            if best == nil { best = prefix }
        }
        return best
    }

    // MARK: - Sweep

    /// Probes `prefix.1 ... prefix.254`, reporting each hit and overall progress.
    func scan(prefix: String,
              onProgress: @escaping @Sendable (Double) -> Void,
              onFound: @escaping @Sendable (DiscoveredPrinter) -> Void) async {
        let hosts = (1...254).map { "\(prefix).\($0)" }
        let batchSize = 48
        var completed = 0

        for batch in stride(from: 0, to: hosts.count, by: batchSize) {
            let slice = Array(hosts[batch..<min(batch + batchSize, hosts.count)])
            await withTaskGroup(of: DiscoveredPrinter?.self) { group in
                for host in slice {
                    group.addTask { [weak self] in await self?.probe(host: host) ?? nil }
                }
                for await result in group {
                    completed += 1
                    onProgress(Double(completed) / Double(hosts.count))
                    if let result { onFound(result) }
                }
            }
        }
        onProgress(1.0)
    }

    private func probe(host: String) async -> DiscoveredPrinter? {
        guard let statusURL = URL(string: "https://\(host)/home/api/device-status") else { return nil }
        var req = URLRequest(url: statusURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["Status"] as? String
        else { return nil }

        // Reached an Apeos. Identity is a bonus -- some models refuse it anonymously.
        var name = "", model = "", serial = "", requiresAuth = false
        if let aboutURL = URL(string: "https://\(host)/home/api/about"),
           let (aData, aResp) = try? await session.data(for: URLRequest(url: aboutURL)),
           let aHTTP = aResp as? HTTPURLResponse {
            if aHTTP.statusCode == 200,
               let a = try? JSONSerialization.jsonObject(with: aData) as? [String: Any] {
                name   = a["DevFrndlName"] as? String ?? ""
                serial = a["SerialNumber"] as? String ?? ""
                model  = a["HostName"] as? String ?? ""
            } else if aHTTP.statusCode == 403 || aHTTP.statusCode == 401 {
                requiresAuth = true
            }
        }
        if name.isEmpty { name = model.isEmpty ? host : model }
        return DiscoveredPrinter(host: host, name: name, model: model,
                                 serial: serial, status: status, requiresAuth: requiresAuth)
    }
}
