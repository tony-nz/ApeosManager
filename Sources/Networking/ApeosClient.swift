import Foundation

enum ApeosError: LocalizedError {
    case badURL
    case http(Int, String)
    case loginFailed(String)
    case notAuthenticated
    case decoding(String)
    case soapFault(String, String)

    var errorDescription: String? {
        switch self {
        case .badURL:                return "Invalid printer address."
        case .http(let c, let p):    return "HTTP \(c) from \(p)"
        case .loginFailed(let r):    return "Login failed (\(r))."
        case .notAuthenticated:      return "This action requires signing in as the printer administrator."
        case .decoding(let d):       return "Unexpected response format: \(d)"
        case .soapFault(let c, let m): return "Device refused the request (\(c)): \(m)"
        }
    }
}

/// Talks to the Apeos/ApeosPort JSON REST API exposed by the device web UI.
///
/// Two families exist on these devices: this JSON API (`/home/api`, `/permissions/api`,
/// `/system/api`) behind a `/LOGIN.cmd` session cookie, and a SOAP/WS-Security layer
/// under `/fb/<ver>/ssm/management`. Only the JSON family is used here.
final class ApeosClient: NSObject {

    let host: String
    private var session: URLSession!
    private(set) var isAuthenticated = false

    /// Retained after sign-in so SOAP calls can build their UsernameToken header.
    var soapCredentials: (user: String, password: String)?
    /// Negotiated on the first authenticated SOAP call; see ApeosSoap.swift.
    var soapAuthStrategy: SoapAuthStrategy?

    var urlSession: URLSession { session }

    init(host: String) {
        self.host = host
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        // An ephemeral configuration already provides an isolated cookie store.
        // Assigning a bare HTTPCookieStorage() here does NOT behave as a real store,
        // and the /LOGIN.cmd `ssid` cookie is then never replayed on later requests.
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: "https://\(host)\(path)") else { throw ApeosError.badURL }
        return u
    }

    // MARK: - Authentication

    /// Credentials are Base64-encoded into form fields `NAME`/`PSW`, matching the
    /// device's own web UI. Success is `{"result":"0"}`; the session rides on a cookie.
    @discardableResult
    func login(userID: String, password: String) async throws -> LoginResult {
        var req = URLRequest(url: try url("/LOGIN.cmd"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let name = Data(userID.utf8).base64EncodedString()
        let psw  = Data(password.utf8).base64EncodedString()
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "NAME", value: name),
                            URLQueryItem(name: "PSW",  value: psw)]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ApeosError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, "/LOGIN.cmd")
        }
        let result = try LoginResult(data: data)
        guard result.ok else { throw ApeosError.loginFailed(result.rawResult) }
        isAuthenticated = true
        soapCredentials = (user: userID, password: password)
        return result
    }

    func logout() async {
        if let u = try? url("/LOGOUT.cmd") {
            var r = URLRequest(url: u); r.httpMethod = "POST"
            _ = try? await session.data(for: r)
        }
        isAuthenticated = false
        soapCredentials = nil
        soapAuthStrategy = nil
    }

    // MARK: - Generic verbs

    func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let data = try await getRaw(path)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ApeosError.decoding("\(path): \(Self.describe(error))") }
    }

    /// DecodingError's default description is a multi-line dump; reduce it to the
    /// one fact that matters when a model returns a different shape.
    static func describe(_ error: Error) -> String {
        guard let d = error as? DecodingError else { return error.localizedDescription }
        switch d {
        case .keyNotFound(let key, _):      return "missing field '\(key.stringValue)'"
        case .typeMismatch(let type, let c):
            let path = c.codingPath.map(\.stringValue).joined(separator: ".")
            return "field '\(path.isEmpty ? "?" : path)' was not \(type)"
        case .valueNotFound(_, let c):
            return "null value for '\(c.codingPath.map(\.stringValue).joined(separator: "."))'"
        case .dataCorrupted(let c):         return c.debugDescription
        @unknown default:                   return error.localizedDescription
        }
    }

    func getRaw(_ path: String) async throws -> Data {
        var req = URLRequest(url: try url(path))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ApeosError.http(-1, path) }
        if http.statusCode == 403 || http.statusCode == 401 { throw ApeosError.notAuthenticated }
        guard (200..<300).contains(http.statusCode) else {
            throw ApeosError.http(http.statusCode, path)
        }
        return data
    }

    /// PUT is what the web UI uses for settings mutations on this API family.
    @discardableResult
    func put(_ path: String, json body: Data) async throws -> Data {
        try await send("PUT", path, body)
    }

    @discardableResult
    func post(_ path: String, json body: Data) async throws -> Data {
        try await send("POST", path, body)
    }

    @discardableResult
    func delete(_ path: String) async throws -> Data {
        try await send("DELETE", path, nil)
    }

    private func send(_ method: String, _ path: String, _ body: Data?) async throws -> Data {
        guard isAuthenticated else { throw ApeosError.notAuthenticated }
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ApeosError.http(-1, path) }
        if http.statusCode == 403 || http.statusCode == 401 { throw ApeosError.notAuthenticated }
        guard (200..<300).contains(http.statusCode) else {
            throw ApeosError.http(http.statusCode, path)
        }
        return data
    }

    // MARK: - Typed reads (unauthenticated on tested firmware)

    func about()        async throws -> DeviceAbout   { try await get("/home/api/about", as: DeviceAbout.self) }
    func status()       async throws -> DeviceStatus  { try await get("/home/api/device-status", as: DeviceStatus.self) }
    func supplies()     async throws -> SuppliesInfo  { try await get("/home/api/supplies-info", as: SuppliesInfo.self) }
    func counters()     async throws -> BillingCounter { try await get("/home/api/billing-counter", as: BillingCounter.self) }
    func trays()        async throws -> PaperTrayInfo { try await get("/home/api/paper-tray", as: PaperTrayInfo.self) }
    func faultHistory() async throws -> FaultHistory  { try await get("/home/api/faulthistory", as: FaultHistory.self) }

    /// The address book, paged. `lang` is required -- omitting it returns
    /// 400 INVALID_PARAMETER -- and the page size matches the device UI's own.
    func addressBook(max: Int = 500) async throws -> [Contact] {
        var all: [Contact] = []
        var offset = 0
        let page = 20
        var total = Int.max
        while offset < min(total, max) {
            let p: AddressBookPage = try await get(
                "/addressbook/api/addressbook?lang=en&offset=\(offset)&limit=\(page)&fetchCount=1",
                as: AddressBookPage.self)
            total = p.contactCount
            if p.contacts.isEmpty { break }
            all.append(contentsOf: p.contacts)
            offset += page
        }
        return all
    }

    /// Completed jobs, newest first, paged.
    ///
    /// The device rejects any limit above 20 with HTTP 500, so more history is reached
    /// by paging: offsetJobID is the last JobID of the previous page and offsetJobIDType
    /// is that job's STATE ("COMPLETED"), not a direction keyword -- passing anything
    /// else silently returns page one again.
    func jobHistory(max: Int = 100) async throws -> [JobRecord] {
        var all: [JobRecord] = []
        var offsetID: Int?
        var offsetType: String?
        var seen = Set<Int>()

        while all.count < max {
            var path = "/jobs/api/job-list?typeFilter=COMPLETED&limit=20"
            if let offsetID, let offsetType {
                path += "&offsetJobID=\(offsetID)&offsetJobIDType=\(offsetType)"
            }
            let page: JobList = try await get(path, as: JobList.self)
            let fresh = page.jobs.filter { !seen.contains($0.jobID) }
            if fresh.isEmpty { break }
            for j in fresh { seen.insert(j.jobID) }
            all.append(contentsOf: fresh)

            guard page.next, let last = page.jobs.last else { break }
            offsetID = last.jobID
            offsetType = last.state == "COMPLETED" ? "COMPLETED" : "UNCOMPLETE"
        }
        return Array(all.prefix(max))
    }

    /// Device identity/contact fields are writable by an administrator.
    func updateAbout(_ about: DeviceAbout) async throws {
        try await put("/home/api/about", json: JSONEncoder().encode(about))
    }

    // MARK: - Accounting (administrator only)

    func internalAccountingRaw()  async throws -> Data { try await getRaw("/permissions/api/internal-accounting") }
    func allUsersManagementRaw()  async throws -> Data { try await getRaw("/permissions/api/all-users-management") }
    func authorizationGroupsRaw() async throws -> Data { try await getRaw("/permissions/api/authorization-groups") }
    func unitPriceRaw()           async throws -> Data { try await getRaw("/permissions/api/unit-price") }
}

// MARK: - Login response

struct LoginResult {
    let rawResult: String
    let passwordChangeRequired: String?
    let snmpDefault: String?
    let globalIP: String?
    var ok: Bool { rawResult == "0" }

    init(data: Data) throws {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ApeosError.decoding("LOGIN.cmd did not return JSON")
        }
        // `result` has been observed as both a quoted string and a bare number.
        if let s = obj["result"] as? String        { rawResult = s }
        else if let n = obj["result"] as? NSNumber { rawResult = n.stringValue }
        else                                        { rawResult = "unknown" }
        passwordChangeRequired = obj["passwordChangeRequired"] as? String
        snmpDefault = obj["snmpDefault"] as? String
        globalIP = obj["globalIP"] as? String
    }
}

// MARK: - Self-signed certificate handling

extension ApeosClient: URLSessionDelegate {
    /// Apeos devices ship a self-signed certificate (CN = the device host name), so the
    /// default trust evaluation always fails. Trust is granted only for the exact host
    /// this client was constructed for — a printer the operator explicitly added.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
