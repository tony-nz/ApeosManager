import Foundation

/// SOAP 1.1 access to the device's SSMI management services.
///
/// Discovered by reading the device's own web UI bundle:
///  * Envelope   `http://schemas.xmlsoap.org/soap/envelope/`
///  * Namespaces `http://www.fujifilm.com` + the service path
///  * Auth       WS-Security-style `Authentication/UsernameToken` in the SOAP header
///  * Endpoints  `/ssm/Management/Aaa/<Service>` (authenticated)
///               `/ssm/Management/Anonymous/Aaa/<Service>` (unauthenticated reads)
///
/// The JSON REST API under `/permissions/api` exposes only capability descriptors;
/// the actual user and department records live here.
/// Appends every SOAP exchange to ~/Library/Logs/ApeosManager/soap.log. This API is
/// undocumented and varies by model, so a durable record of what was sent and what came
/// back is the difference between diagnosing a failure and guessing at it.
extension ApeosClient {
    /// Fault subcodes are terse; give the common ones a plain-language meaning.
    static func explain(_ code: String) -> String {
        switch code.replacingOccurrences(of: "flt:", with: "") {
        case "InvalidMessage":    return "the device rejected the request format"
        case "InternalError":     return "the device reported an internal error (the service may be disabled)"
        case "UnauthorizedUser",
             "PermissionDenied":  return "the signed-in account is not permitted to do this"
        case "InvalidArgument":   return "one of the values was not acceptable"
        case "InvalidOperation":  return "this device does not support that operation"
        case "MaximumSizeExceeded": return "the device has no room for another entry"
        case "AlreadyExists":     return "an entry with that ID already exists"
        default:                  return "the device refused the request"
        }
    }
}

enum SoapLog {
    private static let queue = DispatchQueue(label: "nz.co.myers.ApeosManager.soaplog")
    private static let url: URL? = {
        guard let dir = try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false)
            .appendingPathComponent("Logs/ApeosManager", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("soap.log")
    }()

    static func write(_ text: String) {
        guard let url else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\n[\(stamp)]\n\(text)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

enum SoapAuthStrategy: Equatable {
    case anonymous
    case sessionCookie
    case usernameToken(base64: Bool)
}

extension ApeosClient {

    enum Soap {
        static let ff  = "http://www.fujifilm.com"
        static let env = "http://schemas.xmlsoap.org/soap/envelope/"
        static let cmn = "\(ff)/fb/2021/04/ssm/management/common"
        static let atk = "\(ff)/fb/2021/04/ssm/management/authentication/token"
        static let user    = "\(ff)/fb/2021/04/ssm/management/aaa/user"
        static let account = "\(ff)/fb/2021/04/ssm/management/aaa/account"
        static let role    = "\(ff)/fb/2021/04/ssm/management/aaa/role"

        static let userPath    = "/fb/2021/04/ssm/management/aaa/user"
        static let accountPath = "/fb/2021/04/ssm/management/aaa/account"
        static let rolePath    = "/fb/2021/04/ssm/management/aaa/role"
    }

    // MARK: - Envelope

    private func envelope(ns: String, operation: String, action: String,
                          inner: String, strategy: SoapAuthStrategy) -> String {
        var header = ""
        if case .usernameToken(let base64) = strategy, let c = soapCredentials {
            let pw = base64 ? Data(c.password.utf8).base64EncodedString() : c.password
            header += """
            <atk:Authentication xmlns:atk="\(Soap.atk)">\
            <atk:UsernameToken>\
            <atk:Username>\(Self.xmlEscape(c.user))</atk:Username>\
            <atk:Password>\(Self.xmlEscape(pw))</atk:Password>\
            </atk:UsernameToken></atk:Authentication>
            """
        }
        header += """
        <MessageInformation><MessageExchangeType>RequestResponse</MessageExchangeType>\
        <MessageType>Request</MessageType><Action>\(action)</Action></MessageInformation>
        """
        return """
        <?xml version="1.0" encoding="UTF-8"?>\
        <soap:Envelope xmlns:soap="\(Soap.env)">\
        <soap:Header>\(header)</soap:Header>\
        <soap:Body><o:\(operation) xmlns:o="\(ns)" xmlns:cmn="\(Soap.cmn)">\(inner)</o:\(operation)></soap:Body>\
        </soap:Envelope>
        """
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Sends a SOAP request. Whether the device expects the UsernameToken password
    /// verbatim or Base64-encoded is not stated in the web UI bundle, so on an
    /// authorization fault the call is retried with the other encoding and the
    /// working form is remembered for the rest of the session.
    /// Returns the whole document. Returning `doc.rootElement()` instead would be a
    /// use-after-free hazard: XMLNode holds only a back-pointer to its parent, so the
    /// element is orphaned the moment the XMLDocument goes out of scope and every
    /// subsequent XPath query silently returns nothing.
    @discardableResult
    func soap(service ns: String, path: String, operation: String,
              inner: String, authenticated: Bool = true) async throws -> XMLDocument {
        let action = "\(path)#\(operation)"
        let endpoint = authenticated
            ? "/ssm/Management/Aaa/\(Self.serviceSegment(path))"
            : "/ssm/Management/Anonymous/Aaa/\(Self.serviceSegment(path))"

        // The device's own web UI authenticates SOAP calls with the /LOGIN.cmd session
        // cookie. A UsernameToken header is the documented alternative, and the bundle
        // does not say whether its password is verbatim or Base64 -- so try the cookie
        // first, then both token encodings, and remember whichever the device accepts.
        var strategies: [SoapAuthStrategy] = authenticated
            ? [.sessionCookie, .usernameToken(base64: false), .usernameToken(base64: true)]
            : [.anonymous]
        if let known = soapAuthStrategy, let i = strategies.firstIndex(of: known) {
            strategies.insert(strategies.remove(at: i), at: 0)
        }

        var lastFault = "unknown"
        for strategy in strategies {
            let body = envelope(ns: ns, operation: operation, action: action,
                                inner: inner, strategy: strategy)
            do {
                let doc = try await postSoap(endpoint: endpoint, action: action, body: body)
                soapAuthStrategy = strategy
                guard doc.rootElement() != nil else { throw ApeosError.decoding("empty SOAP response") }
                return doc
            } catch let ApeosError.soapFault(code, message) {
                lastFault = "\(code): \(message)"
                if code.contains("Unauthorized") || code.contains("PermissionDenied") { continue }
                throw ApeosError.soapFault(code, message)
            }
        }
        throw ApeosError.soapFault("flt:UnauthorizedUser", lastFault)
    }

    private static func serviceSegment(_ path: String) -> String {
        // "/fb/2021/04/ssm/management/aaa/user" -> "User"
        let last = path.split(separator: "/").last.map(String.init) ?? "User"
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    private func postSoap(endpoint: String, action: String, body: String) async throws -> XMLDocument {
        var req = URLRequest(url: try soapURL(endpoint))
        req.httpMethod = "POST"
        req.setValue("text/xml;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(action, forHTTPHeaderField: "SOAPAction")
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ApeosError.http(-1, endpoint) }
        SoapLog.write("""
        ===== REQUEST \(host)\(endpoint) =====
        \(body)
        ===== RESPONSE \(http.statusCode) (\(data.count) bytes) =====
        \(String(data: data, encoding: .utf8)?.prefix(1500) ?? "<binary>")
        """)
        guard !data.isEmpty else {
            // An empty body means the device rejected the envelope outright rather
            // than returning a SOAP fault -- almost always an authentication problem.
            throw ApeosError.soapFault("flt:UnauthorizedUser",
                "empty response from \(endpoint) (HTTP \(http.statusCode))")
        }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 500 else {
            throw ApeosError.http(http.statusCode, endpoint)
        }
        let doc = try XMLDocument(data: data, options: [])

        // Two shapes exist: a SOAP-level <Fault>, and per-entry <Faults><Fault> returned
        // inside an otherwise successful 200 response. Both mean the write did not apply.
        if let fault = try? doc.nodes(forXPath: "//*[local-name()='Fault']").first as? XMLElement {
            let str = ((try? fault.nodes(forXPath: ".//*[local-name()='faultstring']").first) ?? nil)?.stringValue
            let sub = ((try? fault.nodes(forXPath: ".//*[local-name()='Value']").first) ?? nil)?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = sub ?? "SOAP:Fault"
            throw ApeosError.soapFault(code, str ?? Self.explain(code))
        }
        return doc
    }

    private func soapURL(_ path: String) throws -> URL {
        guard let u = URL(string: "https://\(host)\(path)") else { throw ApeosError.badURL }
        return u
    }

    // MARK: - Request fragments

    private func scope(offset: Int = 0, limit: Int = 50) -> String {
        "<o:Scope><cmn:Offset>\(offset)</cmn:Offset><cmn:Limit>\(limit)</cmn:Limit></o:Scope>"
    }
    private func responds(_ paths: [String]) -> String {
        "<o:Responds>" + paths.map { "<cmn:Respond>\($0)</cmn:Respond>" }.joined() + "</o:Responds>"
    }

    // MARK: - Departments (Accounts)

    func getAccounts() async throws -> [DeptAccount] {
        // AccountType (empty = all) is required; omitting it yields flt:InternalError.
        // Sort is optional, so drop it rather than fail if a model rejects the key.
        let fields = responds(["Accounts/Account/AccountID",
                               "Accounts/Account/Name",
                               "Accounts/Account/NewUserDefault",
                               "Accounts/Account/Usage/#CHILD"])
        let sorted = "<o:AccountType></o:AccountType>"
            + "<o:Sort><cmn:Key order=\"ascending\">Name</cmn:Key></o:Sort>"
            + scope() + fields
        let unsorted = "<o:AccountType></o:AccountType>" + scope() + fields
        let inner = sorted
        var doc: XMLDocument
        do {
            doc = try await soap(service: Soap.account, path: Soap.accountPath,
                                 operation: "GetAccount", inner: inner)
        } catch let ApeosError.soapFault(code, _) where code.contains("InvalidMessage") {
            doc = try await soap(service: Soap.account, path: Soap.accountPath,
                                 operation: "GetAccount", inner: unsorted)
        }
        let nodes = (try? doc.nodes(forXPath: "//*[local-name()='Account']")) ?? []
        return nodes.compactMap { node in
            guard let el = node as? XMLElement else { return nil }
            let id = Self.child(el, "AccountID") ?? ""
            guard !id.isEmpty else { return nil }
            var usage: [String: Int] = [:]
            if let u = (try? el.nodes(forXPath: "./*[local-name()='Usage']").first) as? XMLElement {
                for c in u.children ?? [] {
                    if let ce = c as? XMLElement, let v = Int(ce.stringValue ?? "") {
                        usage[ce.localName ?? "?"] = v
                    }
                }
            }
            return DeptAccount(accountID: id,
                               name: Self.child(el, "Name") ?? "",
                               newUserDefault: (Self.child(el, "NewUserDefault") ?? "false") == "true",
                               usage: usage)
        }
    }

    func setAccount(_ a: DeptAccount) async throws {
        let inner = """
        <o:Accounts><o:Account>\
        <o:AccountID>\(Self.xmlEscape(a.accountID))</o:AccountID>\
        <o:Name>\(Self.xmlEscape(a.name))</o:Name>\
        <o:NewUserDefault>\(a.newUserDefault)</o:NewUserDefault>\
        </o:Account></o:Accounts>
        """
        try await soap(service: Soap.account, path: Soap.accountPath, operation: "SetAccount", inner: inner)
    }

    func addAccount(_ a: DeptAccount) async throws {
        let inner = """
        <o:Accounts><o:Account>\
        <o:AccountID>\(Self.xmlEscape(a.accountID))</o:AccountID>\
        <o:Name>\(Self.xmlEscape(a.name))</o:Name>\
        <o:NewUserDefault>\(a.newUserDefault)</o:NewUserDefault>\
        </o:Account></o:Accounts>
        """
        try await soap(service: Soap.account, path: Soap.accountPath, operation: "AddAccount", inner: inner)
    }

    func deleteAccount(id: String) async throws {
        let inner = "<o:Accounts><o:Account><o:AccountID>\(Self.xmlEscape(id))</o:AccountID></o:Account></o:Accounts>"
        try await soap(service: Soap.account, path: Soap.accountPath, operation: "DeleteAccount", inner: inner)
    }

    // MARK: - Users

    /// Mirrors the request the device's own web UI issues for its user list.
    /// Element order matters (the schema is a sequence) and `Responds` paths are
    /// RELATIVE to each User element -- "Users/User/..." belongs to a different
    /// operation and silently selects nothing.
    func getUsers() async throws -> [DeviceUser] {
        let base = ["Authentication/UserID",
                    "Authentication/UserType",
                    "Authentication/UserName",
                    "Authentication/Initials",
                    "Authorization/Role/#DESCENDANT",
                    "Accounting/Usage/#CHILD"]
        do {
            // Models differ over which block reports the name, so ask for both.
            return try await fetchUsers(responds: base + ["Accounting/UserName"])
        } catch let ApeosError.soapFault(code, _) where code.contains("InvalidMessage") {
            // Older firmware may not expose the accounting name on this operation.
            return try await fetchUsers(responds: base)
        }
    }

    /// The device pages this collection (its own UI uses 20 per request) and an
    /// oversized Limit yields an empty set rather than a fault, so pages are walked
    /// until NumberOfUsers is satisfied.
    private func fetchUsers(responds paths: [String]) async throws -> [DeviceUser] {
        var all: [DeviceUser] = []
        var offset = 0
        let pageSize = 50
        var total = Int.max

        while offset < total {
            let (page, reported) = try await fetchUserPage(offset: offset, limit: pageSize,
                                                           responds: paths)
            if let reported { total = reported }
            if page.isEmpty { break }
            all.append(contentsOf: page)
            offset += pageSize
            if all.count >= total { break }
        }
        return all
    }

    private func fetchUserPage(offset: Int, limit: Int,
                               responds paths: [String]) async throws -> ([DeviceUser], Int?) {
        let inner = """
        <o:UserTypes><o:UserType>KO</o:UserType><o:UserType>CO</o:UserType></o:UserTypes>\
        <o:Sort><cmn:Key order="ascending">UserID</cmn:Key></o:Sort>\
        <o:Scope><cmn:Offset>\(offset)</cmn:Offset><cmn:Limit>\(limit)</cmn:Limit></o:Scope>
        """ + responds(paths)

        let doc = try await soap(service: Soap.user, path: Soap.userPath,
                                 operation: "GetUserInformation", inner: inner)
        let total = ((try? doc.nodes(forXPath: "//*[local-name()='NumberOfUsers']").first) ?? nil)?
            .stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let nodes = (try? doc.nodes(forXPath: "//*[local-name()='User']")) ?? []
        let users: [DeviceUser] = nodes.compactMap { node in
            guard let el = node as? XMLElement else { return nil }
            let id = Self.descendant(el, "UserID") ?? ""
            guard !id.isEmpty else { return nil }
            let roles = ((try? el.nodes(forXPath: ".//*[local-name()='RoleID']/*[local-name()='Name']")) ?? [])
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let assoc = ((try? el.nodes(forXPath: ".//*[local-name()='AccountID']")) ?? [])
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let usage = ((try? el.nodes(forXPath: ".//*[local-name()='Usage']")) ?? [])
                .compactMap { node -> UsageMeter? in
                    guard let u = node as? XMLElement,
                          let type = Self.descendant(u, "Type") else { return nil }
                    return UsageMeter(type: type,
                                      limit: Self.descendant(u, "Limit").flatMap(Int.init),
                                      used: Self.descendant(u, "Used").flatMap(Int.init) ?? 0,
                                      remaining: Self.descendant(u, "Remaining").flatMap(Int.init))
                }
            return DeviceUser(userID: id,
                              userName: Self.descendant(el, "UserName") ?? "",
                              userType: Self.descendant(el, "UserType") ?? "CO",
                              initials: Self.descendant(el, "Initials") ?? "",
                              roles: roles,
                              usage: usage,
                              associates: Array(Set(assoc)).sorted())
        }
        if ProcessInfo.processInfo.environment["APEOS_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                "PARSED page offset=\(offset): \(users.count) users, total=\(total.map(String.init) ?? "nil")\n".utf8))
        }
        return (users, total)
    }

    /// Creates a user.
    ///
    /// Verified against hardware: AddUserInformation succeeds with an Authentication
    /// block carrying only UserType and UserID. Including an Accounting block in the
    /// same request is what the device rejects with flt:InvalidMessage -- so the name
    /// and password are applied afterwards with SetUserInformation, which only works
    /// once the record exists.
    func addUser(_ u: DeviceUser, password: String?) async throws {
        let inner = """
        <o:Users><o:User><o:Authentication>\
        <o:UserType>\(u.userType)</o:UserType>\
        <o:UserID>\(Self.xmlEscape(u.userID))</o:UserID>\
        </o:Authentication></o:User></o:Users>
        """
        try await soap(service: Soap.user, path: Soap.userPath,
                       operation: "AddUserInformation", inner: inner)

        if !u.userName.isEmpty || !(password ?? "").isEmpty {
            try await writeUser(u, password: password)
        }
    }

    func setUser(_ u: DeviceUser) async throws {
        try await writeUser(u, password: nil)
    }

    /// Applies name and/or password to an existing user.
    ///
    /// Verified by read-after-write on hardware: the display name persists ONLY via
    /// Authentication/UserName. Writing Accounting/UserName returns HTTP 200 with no
    /// fault and silently discards the value, so a success response proves nothing
    /// here -- the caller re-reads to confirm.
    /// Sets accounting limits for a user. The device's own UI writes these as an
    /// Accounting block keyed by UserType/UserID with one Usage{Type, Limit} per meter;
    /// Used and Remaining are read-only and must not be sent.
    func setUsageLimits(_ u: DeviceUser, limits: [String: Int]) async throws {
        guard !limits.isEmpty else { return }
        let entries = limits.sorted { $0.key < $1.key }.map { type, limit in
            "<o:Usage><o:Type>\(type)</o:Type><o:Limit>\(limit)</o:Limit></o:Usage>"
        }.joined()
        let inner = """
        <o:Users><o:User><o:Accounting>\
        <o:UserType>\(u.userType)</o:UserType>\
        <o:UserID>\(Self.xmlEscape(u.userID))</o:UserID>\
        \(entries)</o:Accounting></o:User></o:Users>
        """
        try await soap(service: Soap.user, path: Soap.userPath,
                       operation: "SetUserInformation", inner: inner)
    }

    /// Clears a user's accounting counters (the Used figures), leaving limits alone.
    func clearUsageCounters(_ u: DeviceUser) async throws {
        let inner = """
        <o:User><o:UserType>\(u.userType)</o:UserType>\
        <o:UserID>\(Self.xmlEscape(u.userID))</o:UserID></o:User>
        """
        try await soap(service: Soap.user, path: Soap.userPath,
                       operation: "ClearUserUsageCounter", inner: inner)
    }

    private func writeUser(_ u: DeviceUser, password: String?) async throws {
        var auth = """
        <o:UserType>\(u.userType)</o:UserType>\
        <o:UserID>\(Self.xmlEscape(u.userID))</o:UserID>
        """
        if !u.userName.isEmpty {
            auth += "<o:UserName>\(Self.xmlEscape(u.userName))</o:UserName>"
        }
        if let password, !password.isEmpty {
            auth += "<o:Password>\(Self.xmlEscape(password))</o:Password>"
        }
        let inner = "<o:Users><o:User><o:Authentication>\(auth)</o:Authentication></o:User></o:Users>"
        try await soap(service: Soap.user, path: Soap.userPath,
                       operation: "SetUserInformation", inner: inner)
    }

    /// Deletes a user.
    ///
    /// This operation does NOT take the Users/User/Authentication shape the read and
    /// write calls use -- its schema is Category + User{UserType, UserID}, and the web
    /// UI passes the literal Category "Authentication". Sending the wrong shape returns
    /// HTTP 500 with no fault detail.
    func deleteUser(id: String, userType: String = "CO") async throws {
        let inner = """
        <o:Category>Authentication</o:Category>\
        <o:User><o:UserType>\(userType)</o:UserType>\
        <o:UserID>\(Self.xmlEscape(id))</o:UserID></o:User>
        """
        try await soap(service: Soap.user, path: Soap.userPath,
                       operation: "DeleteUserInformationAsync", inner: inner)
    }

    func associateUser(_ userID: String, withAccount accountID: String) async throws {
        let inner = """
        <o:AccountID>\(Self.xmlEscape(accountID))</o:AccountID>\
        <o:Users><o:User><o:Authentication><o:UserType>CO</o:UserType>\
        <o:UserID>\(Self.xmlEscape(userID))</o:UserID></o:Authentication></o:User></o:Users>
        """
        try await soap(service: Soap.account, path: Soap.accountPath,
                       operation: "AssociateUserWithAccount", inner: inner)
    }

    private static func child(_ el: XMLElement, _ name: String) -> String? {
        ((try? el.nodes(forXPath: "./*[local-name()='\(name)']").first) ?? nil)?.stringValue
    }

    /// Identity fields sit at varying depths inside a User element, so match on the
    /// first descendant with the given local name.
    static func descendant(_ el: XMLElement, _ name: String) -> String? {
        let v = ((try? el.nodes(forXPath: ".//*[local-name()='\(name)']").first) ?? nil)?.stringValue
        let t = v?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }
}
