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

    /// Adds a person to the address book with one email destination.
    ///
    /// Three body shapes are tried in the order the write probe established, because the
    /// device answers 200 to a create it does not perform: the read-back after each is
    /// what decides, not the status code. Returns the ContactId the device assigned.
    ///
    /// Throws if none of the shapes took, so the caller can report that the user was
    /// created but the address book entry was not.
    @discardableResult
    func addContact(displayName: String, email: String) async throws -> String {
        // Built from a contact the device already holds, with the identity swapped out.
        // Composing a record from the documented-looking field names created the contact
        // but silently dropped its DestList -- the entry appeared with no channel and no
        // address. Mirroring a real record carries whatever else this firmware wants on a
        // destination (DestFavorite, OneTouchKeyId, fields not modelled here) without
        // having to know what they are.
        var bodies: [[String: Any]] = []
        if var sample = try await contactWithEmailDestination() {
            var dests = sample["DestList"] as? [[String: Any]] ?? []
            if var first = dests.first {
                // Ids are assigned by the device; carrying another contact's would either
                // be rejected or, worse, overwrite theirs.
                first.removeValue(forKey: "DestId")
                first.removeValue(forKey: "OneTouchKeyId")
                first["SaveType"] = "ADD"
                var detail = first["Email"] as? [String: Any] ?? [:]
                detail["MailAddress"] = email
                first["Email"] = detail
                dests = [first]
            }
            sample.removeValue(forKey: "ContactId")
            sample["DisplayName"] = displayName
            sample["LastName"] = ""
            sample["FirstName"] = ""
            sample["CompanyName"] = ""
            sample["Key"] = displayName.lowercased()
            sample["Favorite"] = false
            sample["DestList"] = dests
            bodies.append(sample)
        }

        // Fallbacks. `SaveType` is the field that makes a destination stick: the web UI
        // bundle declares SaveType = {ADD, EDIT, DELETED, DEL_AND_ADD} on its destination
        // model, and a DestList entry without one is a destination the device has been
        // given no instruction about -- it creates the contact and silently drops it,
        // answering {"Result":"SUCCESS"} either way.
        let dest: [String: Any] = [
            "SaveType": "ADD", "DestType": "EMAIL", "DestFavorite": false,
            "Email": ["MailAddress": email]
        ]
        bodies.append([
            "ContactType": "PERSON", "DisplayName": displayName,
            "LastName": "", "FirstName": "", "CompanyName": "",
            "Key": displayName.lowercased(), "Favorite": false, "DestList": [dest]
        ])
        bodies.append(["ContactType": "PERSON", "DisplayName": displayName, "DestList": [dest]])

        var lastNote = "no response"
        for body in bodies {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { continue }
            let response = (try? await post("/addressbook/api/contact", json: data)) ?? Data()
            DeviceLog.write("""
            ===== ADDRESS BOOK CREATE \(host) =====
            \(String(data: data, encoding: .utf8) ?? "<unencodable>")
            ===== RESPONSE =====
            \(String(data: response, encoding: .utf8) ?? "<empty>")
            """)

            guard let made = try await contact(named: displayName) else {
                lastNote = "the printer did not store the entry"
                continue
            }
            // Created is not enough: a contact with no destination cannot be scanned to,
            // which is the whole reason for filing it.
            let stored = (made["DestList"] as? [[String: Any]]) ?? []
            if stored.isEmpty {
                lastNote = "the entry was created without its email address"
                if let id = made["ContactId"] as? String { try? await deleteContact(id: id) }
                continue
            }
            return made["ContactId"] as? String ?? ""
        }
        throw ApeosError.decoding(lastNote)
    }

    /// Removes a contact. Used to clear up a half-made entry rather than leave a
    /// destination-less contact behind for somebody to find and wonder about.
    /// Both forms the write probe found are tried, confirmed by read-back, because
    /// neither was ever established as the one this firmware honours.
    @discardableResult
    func deleteContact(id: String) async throws -> Bool {
        _ = try? await delete("/addressbook/api/contact?contactId=\(id)")
        if try await rawContact(id: id) == nil { return true }

        if let body = try? JSONSerialization.data(withJSONObject: ["ContactIdList": [id]]) {
            _ = try? await post("/addressbook/api/addressbook", json: body)
        }
        return try await rawContact(id: id) == nil
    }

    /// Renames a contact and/or changes its email address.
    ///
    /// The record the device returned is sent back with only the changed fields altered,
    /// for the same reason the favourite write does it: this endpoint accepts the shape
    /// it hands out. The destination carries `SaveType` -- EDIT where one already exists,
    /// ADD where the contact had none -- without which the device keeps the contact and
    /// discards the destination while still answering SUCCESS.
    func updateContact(id: String, displayName: String, company: String,
                       email: String) async throws {
        guard var record = try await rawContact(id: id) else {
            throw ApeosError.decoding("the printer no longer lists this contact")
        }
        record["DisplayName"] = displayName
        record["CompanyName"] = company
        record["Key"] = displayName.lowercased()

        var dests = record["DestList"] as? [[String: Any]] ?? []
        if let i = dests.firstIndex(where: { $0["DestType"] as? String == "EMAIL" }) {
            if email.isEmpty {
                dests[i]["SaveType"] = "DELETED"
            } else {
                dests[i]["SaveType"] = "EDIT"
                var detail = dests[i]["Email"] as? [String: Any] ?? [:]
                detail["MailAddress"] = email
                dests[i]["Email"] = detail
            }
        } else if !email.isEmpty {
            dests.append(["SaveType": "ADD", "DestType": "EMAIL", "DestFavorite": false,
                          "Email": ["MailAddress": email]])
        }
        record["DestList"] = dests

        let body = try JSONSerialization.data(withJSONObject: record)
        let response = try await put("/addressbook/api/contact", json: body)
        DeviceLog.write("""
        ===== ADDRESS BOOK UPDATE \(host) =====
        \(String(data: body, encoding: .utf8) ?? "<unencodable>")
        ===== RESPONSE =====
        \(String(data: response, encoding: .utf8) ?? "<empty>")
        """)

        // Confirmed by re-reading, because SUCCESS here means only that the request
        // parsed. A rename that did not take, or an address the device dropped, both
        // come back as 200.
        guard let after = try await rawContact(id: id) else {
            throw ApeosError.decoding("the contact vanished from the printer")
        }
        if (after["DisplayName"] as? String) != displayName {
            throw ApeosError.decoding("the printer did not store the name")
        }
        let stored = ((after["DestList"] as? [[String: Any]]) ?? [])
            .compactMap { ($0["Email"] as? [String: Any])?["MailAddress"] as? String }
        if !email.isEmpty, !stored.contains(where: { $0.lowercased() == email.lowercased() }) {
            throw ApeosError.decoding("the printer did not store the email address")
        }
    }

    /// Removes the address book entry whose email destination is this address, if the
    /// book holds one. Returns the display name removed, or nil if there was nothing to
    /// remove.
    ///
    /// Matched on the address rather than the name deliberately. A name match would put
    /// shared entries at risk -- "Library" or "Day Care" is a mailbox, not a person --
    /// whereas the address is the thing that actually ties an entry to one account.
    func deleteContact(withEmail email: String) async throws -> String? {
        let wanted = email.lowercased()
        guard let record = try await findContact({ rec in
            guard let dests = rec["DestList"] as? [[String: Any]] else { return false }
            return dests.contains { d in
                let address = (d["Email"] as? [String: Any])?["MailAddress"] as? String
                return address?.lowercased() == wanted
            }
        }), let id = record["ContactId"] as? String else { return nil }

        let name = record["DisplayName"] as? String ?? id
        return try await deleteContact(id: id) ? name : nil
    }

    /// Any contact that already has an email destination, to copy the shape from.
    private func contactWithEmailDestination() async throws -> [String: Any]? {
        try await findContact { record in
            guard let dests = record["DestList"] as? [[String: Any]] else { return false }
            return dests.contains { $0["DestType"] as? String == "EMAIL" && $0["Email"] != nil }
        }
    }

    /// A contact by display name, as the device returns it. Used to confirm a create,
    /// which is the only way to know one happened.
    private func contact(named name: String) async throws -> [String: Any]? {
        try await findContact { $0["DisplayName"] as? String == name }
    }

    /// Marks a contact as a favourite, or clears it.
    ///
    /// The record is re-read and sent back whole with only `Favorite` changed. Two
    /// reasons it works this way rather than PUTting a small patch: the device accepts
    /// the shape it hands out and is unreliable about partial bodies, and the address
    /// book endpoint answers 200 to writes it silently discards -- so the caller cannot
    /// trust the response and the change is confirmed by reading the contact back.
    ///
    /// Returns the favourite state the device actually holds afterwards.
    @discardableResult
    func setFavorite(contactId: String, to value: Bool) async throws -> Bool {
        guard var record = try await rawContact(id: contactId) else {
            throw ApeosError.decoding("the printer no longer lists this contact")
        }
        record["Favorite"] = value
        let body = try JSONSerialization.data(withJSONObject: record)
        try await put("/addressbook/api/contact", json: body)

        let after = try await rawContact(id: contactId)
        return (after?["Favorite"] as? Bool) ?? false
    }

    /// One contact exactly as the device returns it, found by walking the same pages the
    /// list read uses. There is no by-id read on this endpoint.
    private func rawContact(id: String) async throws -> [String: Any]? {
        try await findContact { $0["ContactId"] as? String == id }
    }

    /// Walks the same pages the list read uses, looking for one record. There is no
    /// by-id or by-name read on this endpoint, so paging is the only way in.
    private func findContact(_ matches: ([String: Any]) -> Bool) async throws -> [String: Any]? {
        var offset = 0
        let page = 20
        var total = Int.max
        while offset < total {
            let data = try await getRaw(
                "/addressbook/api/addressbook?lang=en&offset=\(offset)&limit=\(page)&fetchCount=1")
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if total == Int.max {
                let count = obj["ContactCount"]
                total = (count as? Int)
                    ?? ((count as? [String: Any])?["ContactCount"] as? Int)
                    ?? 0
            }
            let list = obj["ContactList"] as? [[String: Any]] ?? []
            if list.isEmpty { return nil }
            if let hit = list.first(where: matches) { return hit }
            offset += page
        }
        return nil
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

    /// The device's numbered permission groups, for the picker in the user permissions
    /// editor.
    ///
    /// Parsed leniently rather than through a Codable shape: this endpoint wraps its
    /// payload in a per-model envelope key, and the group list is worth having even
    /// when the wrapper is not the one this was written against.
    func authorizationGroups() async throws -> [AuthorizationGroup] {
        let json = try JSONSerialization.jsonObject(with: try await authorizationGroupsRaw())
        guard let array = Self.findArray(named: "AuthorizationGroups", in: json) else { return [] }
        return array.compactMap { entry in
            guard let row = entry as? [String: Any] else { return nil }
            let number = (row["GroupNumber"] as? Int)
                ?? (row["GroupNumber"] as? String).flatMap(Int.init)
            guard let number else { return nil }
            return AuthorizationGroup(number: number, name: row["GroupName"] as? String ?? "")
        }
        .sorted { $0.number < $1.number }
    }

    /// Depth-first search for a named array, whatever envelope the model wraps it in.
    private static func findArray(named key: String, in json: Any) -> [Any]? {
        guard let object = json as? [String: Any] else { return nil }
        if let hit = object[key] as? [Any] { return hit }
        for value in object.values {
            if let hit = findArray(named: key, in: value) { return hit }
        }
        return nil
    }
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
