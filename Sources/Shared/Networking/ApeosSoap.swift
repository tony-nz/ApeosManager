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

/// The same file, under the name that fits when the traffic is not SOAP. The JSON
/// address book writes are logged here too: they are the calls whose accepted body shape
/// had to be discovered by trying, so a record of what was sent is what makes the next
/// failure diagnosable.
typealias DeviceLog = SoapLog

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
    /// until the device stops returning records.
    ///
    /// Two things this must not do, both of which silently truncated the directory:
    ///
    /// - **Advance by the requested page size.** A model may cap its page below the
    ///   requested Limit, and stepping by `pageSize` then skips every record between
    ///   what came back and the next offset. Step by what the device actually sent.
    /// - **Terminate on NumberOfUsers.** It is not a dependable count of the whole
    ///   collection, so `all.count >= total` ended the walk early and the tail of the
    ///   directory never loaded. It is ignored here; an empty page is the terminator.
    private func fetchUsers(responds paths: [String]) async throws -> [DeviceUser] {
        var all: [DeviceUser] = []
        var seen = Set<String>()
        var offset = 0
        let pageSize = 50
        // Bounds the walk if a device neither pages nor empties: 200 x 50 records.
        let maxPages = 200

        for _ in 0..<maxPages {
            let (page, _, rawCount) = try await fetchUserPage(offset: offset, limit: pageSize,
                                                              responds: paths)
            guard rawCount > 0 else { break }
            let fresh = page.filter { seen.insert($0.userID).inserted }
            // A device that ignores Offset replays page one forever. Once a whole page
            // is records already held, walking further cannot add anything.
            guard !fresh.isEmpty else { break }
            all.append(contentsOf: fresh)
            // rawCount, not fresh.count: a record the parser rejects still occupies a
            // slot in the device's ordering, and skipping it would re-read for ever.
            offset += rawCount
        }
        return all
    }

    /// Returns the parsed users, the device's reported NumberOfUsers, and how many
    /// `User` elements the response actually carried -- the last is what paging must
    /// step by, since it counts records the parser discarded too.
    private func fetchUserPage(offset: Int, limit: Int,
                               responds paths: [String]) async throws -> ([DeviceUser], Int?, Int) {
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
                "PARSED page offset=\(offset) limit=\(limit): \(nodes.count) records, \(users.count) parsed, total=\(total.map(String.init) ?? "nil")\n".utf8))
        }
        return (users, total, nodes.count)
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
    /// Sets accounting limits for a user. The limits themselves go in an Accounting
    /// block keyed by UserType/UserID with one Usage{Type, Limit} per meter; Used and
    /// Remaining are read-only and must not be sent.
    ///
    /// The Authentication block is not redundant with the one inside Accounting. The
    /// User element is a schema sequence, and the device identifies the record it is
    /// writing from Authentication; sending Accounting on its own answered HTTP 200
    /// carrying a per-entry flt:InternalError and applied nothing, while every
    /// SetUserInformation that has ever succeeded here -- including one whose payload
    /// was an Accounting block -- led with Authentication.
    func setUsageLimits(_ u: DeviceUser, limits: [String: Int]) async throws {
        guard !limits.isEmpty else { return }
        // Emitted in the device's own reporting order (colour before mono, Copy/Print/
        // Scan), not sorted by name: this is a schema sequence, and alphabetical order
        // would put CopyBW ahead of CopyColor -- the reverse of how the device lists them.
        let entries = UsageMeter.allTypes.compactMap { type in
            limits[type].map { "<o:Usage><o:Type>\(type)</o:Type><o:Limit>\($0)</o:Limit></o:Usage>" }
        }.joined()
        let ident = """
        <o:UserType>\(u.userType)</o:UserType>\
        <o:UserID>\(Self.xmlEscape(u.userID))</o:UserID>
        """
        let inner = """
        <o:Users><o:User>\
        <o:Authentication>\(ident)</o:Authentication>\
        <o:Accounting>\(ident)\(entries)</o:Accounting>\
        </o:User></o:Users>
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

// MARK: - User permissions and e-mail address

/// The per-user permission fields, and the "From" address used when that user scans to
/// e-mail. Both live on `GetUserInformation`/`SetUserInformation` alongside the
/// accounting meters, under paths the device's own account page selects:
///
/// - `Authentication/MailAddress`
/// - `Authentication/ProhibitLoginWith/{ManualEntry,CardEntry}`
/// - `Authorization/TraditionalRole`
/// - `Authorization/PermissionGroup/{Index,Name}`
/// - `Authorization/ColorModePermission/{Copy,Fax,Scan,Print}`
extension ApeosClient {

    /// Every field, for a device with a fax, a card reader and colour.
    private static let permissionPaths = [
        "Authentication/UserID",
        "Authentication/UserType",
        "Authentication/ProhibitLoginWith/ManualEntry",
        "Authentication/ProhibitLoginWith/CardEntry",
        "Authentication/MailAddress",
        "Authorization/TraditionalRole",
        "Authorization/PermissionGroup/Index",
        "Authorization/PermissionGroup/Name",
        "Authorization/ColorModePermission/Copy",
        "Authorization/ColorModePermission/Fax",
        "Authorization/ColorModePermission/Scan",
        "Authorization/ColorModePermission/Print",
    ]

    /// Without the two optional accessories. A `Responds` path naming an element the
    /// model does not have is answered `flt:InvalidMessage` for the whole request, so
    /// the ones that depend on hardware are dropped before giving up altogether.
    private static let permissionPathsLean = permissionPaths.filter {
        !$0.hasSuffix("CardEntry") && !$0.hasSuffix("ColorModePermission/Fax")
    }

    /// The e-mail address on its own -- the last thing worth asking for if the
    /// permission elements are not available on this model.
    private static let mailOnlyPaths = [
        "Authentication/UserID", "Authentication/UserType", "Authentication/MailAddress",
    ]

    /// Reads one user's permission and e-mail fields.
    ///
    /// Falls back through progressively smaller field sets, because the device answers
    /// a request naming an element it does not implement with a fault covering the
    /// whole request rather than by omitting that one value.
    func getUserPermissions(userID: String) async throws -> UserPermissions {
        var lastFault: Error?
        for paths in [Self.permissionPaths, Self.permissionPathsLean, Self.mailOnlyPaths] {
            do {
                return try await withUserRecord(userID: userID, responds: paths) {
                    Self.parsePermissions($0)
                }
            } catch let error as ApeosError {
                guard case .soapFault(let code, _) = error, code.contains("InvalidMessage") else {
                    throw error
                }
                lastFault = error
            }
        }
        throw lastFault ?? ApeosError.decoding("no permission fields for user '\(userID)'")
    }

    /// Writes the permission fields, in the device's own two steps: the panel
    /// permissions here, the e-mail address separately.
    ///
    /// Only fields present in `permissions` are sent. A nil field means the device
    /// never reported it, and sending it anyway is what draws `flt:InvalidMessage`.
    func setUserPermissions(userID: String, userType: String, _ p: UserPermissions) async throws {
        var auth = """
        <o:UserType>\(userType)</o:UserType>\
        <o:UserID>\(Self.xmlEscape(userID))</o:UserID>
        """
        // Element order is the schema's, not ours: User, Authentication and
        // Authorization are all sequences, and out-of-order children are rejected.
        if let login = p.login {
            auth += "<o:ProhibitLoginWith><o:ManualEntry>\(login.prohibitsManualEntry)</o:ManualEntry>"
            if p.cardLoginSupported {
                auth += "<o:CardEntry>\(login.prohibitsCardEntry)</o:CardEntry>"
            }
            auth += "</o:ProhibitLoginWith>"
        }

        var authz = ""
        if let role = p.role {
            authz += "<o:TraditionalRole>\(role.rawValue)</o:TraditionalRole>"
        }
        if let group = p.group {
            // Index and Name travel together; the device's own editor sends both.
            authz += """
            <o:PermissionGroup><o:Index>\(group.number)</o:Index>\
            <o:Name>\(Self.xmlEscape(group.name))</o:Name></o:PermissionGroup>
            """
        }
        let modes = PermissionService.allCases.compactMap { service in
            p.access[service].map { "<o:\(service.rawValue)>\($0.rawValue)</o:\(service.rawValue)>" }
        }.joined()
        if !modes.isEmpty { authz += "<o:ColorModePermission>\(modes)</o:ColorModePermission>" }

        guard !authz.isEmpty || p.login != nil else { return }
        let inner = """
        <o:Users><o:User><o:Authentication>\(auth)</o:Authentication>\
        \(authz.isEmpty ? "" : "<o:Authorization>\(authz)</o:Authorization>")\
        </o:User></o:Users>
        """
        try await soap(service: Soap.user, path: Soap.userPath,
                       operation: "SetUserInformation", inner: inner)
    }

    /// Sets the address a user's scans are sent "From". An empty string clears it.
    func setUserMailAddress(userID: String, userType: String, _ address: String) async throws {
        let inner = """
        <o:Users><o:User><o:Authentication>\
        <o:UserType>\(userType)</o:UserType>\
        <o:UserID>\(Self.xmlEscape(userID))</o:UserID>\
        <o:MailAddress>\(Self.xmlEscape(address))</o:MailAddress>\
        </o:Authentication></o:User></o:Users>
        """
        try await soap(service: Soap.user, path: Soap.userPath,
                       operation: "SetUserInformation", inner: inner)
    }

    // MARK: Reading one record

    /// Runs `parse` over one user's `User` element.
    ///
    /// The device's own account page narrows `GetUserInformation` to a single record
    /// with a leading `UserIDs/UserID` -- the first element of that operation's
    /// sequence, and the only filter shape the device accepts. Should a model ignore
    /// or reject it the collection is walked instead, which also tells a rejected
    /// filter apart from a `Responds` path the model does not implement: only the
    /// latter faults on the unfiltered request too.
    ///
    /// The parsing happens in a closure because an XMLElement is only a back-pointer
    /// into its document; returning one outlives the document and yields nothing.
    private func withUserRecord<T>(userID: String, responds paths: [String],
                                   _ parse: (XMLElement) -> T) async throws -> T {
        let filter = "<o:UserIDs><o:UserID>\(Self.xmlEscape(userID))</o:UserID></o:UserIDs>"
        do {
            let doc = try await soap(service: Soap.user, path: Soap.userPath,
                                     operation: "GetUserInformation",
                                     inner: filter + responds(paths))
            if let el = Self.userElement(in: doc, userID: userID) { return parse(el) }
        } catch let ApeosError.soapFault(code, message) {
            guard code.contains("InvalidMessage") else {
                throw ApeosError.soapFault(code, message)
            }
        }

        var offset = 0
        let pageSize = 50
        for _ in 0..<200 {
            let inner = """
            <o:UserTypes><o:UserType>KO</o:UserType><o:UserType>CO</o:UserType></o:UserTypes>\
            <o:Sort><cmn:Key order="ascending">UserID</cmn:Key></o:Sort>\
            <o:Scope><cmn:Offset>\(offset)</cmn:Offset><cmn:Limit>\(pageSize)</cmn:Limit></o:Scope>
            """ + responds(paths)
            let doc = try await soap(service: Soap.user, path: Soap.userPath,
                                     operation: "GetUserInformation", inner: inner)
            let count = ((try? doc.nodes(forXPath: "//*[local-name()='User']")) ?? []).count
            guard count > 0 else { break }
            if let el = Self.userElement(in: doc, userID: userID) { return parse(el) }
            offset += count
        }
        throw ApeosError.decoding("the device did not return a record for user '\(userID)'")
    }

    private static func userElement(in doc: XMLDocument, userID: String) -> XMLElement? {
        let nodes = (try? doc.nodes(forXPath: "//*[local-name()='User']")) ?? []
        return nodes.compactMap { $0 as? XMLElement }
                    .first { descendant($0, "UserID") == userID }
    }

    private static func parsePermissions(_ el: XMLElement) -> UserPermissions {
        var out = UserPermissions()

        // MailAddress is reported as an empty element when unset, which is a different
        // thing from a device that does not report it at all -- the first is editable,
        // the second must not be written. `descendant` maps empty to nil, so presence
        // is decided on the element rather than its value.
        if element(el, "MailAddress") != nil {
            out.mailAddress = descendant(el, "MailAddress") ?? ""
        }

        if let login = element(el, "ProhibitLoginWith") {
            let card = trimmedChild(login, "CardEntry").flatMap(Self.bool)
            out.cardLoginSupported = card != nil
            out.login = LoginPermission(
                prohibitsManualEntry: trimmedChild(login, "ManualEntry").flatMap(Self.bool) ?? false,
                prohibitsCardEntry: card)
        }

        out.role = descendant(el, "TraditionalRole").flatMap(TraditionalRole.init(rawValue:))

        if let group = element(el, "PermissionGroup"),
           let index = trimmedChild(group, "Index").flatMap(Int.init) {
            // Scoped to the element: `Name` also appears under Authorization/Role/RoleID.
            out.group = AuthorizationGroup(number: index, name: trimmedChild(group, "Name") ?? "")
        }

        if let modes = element(el, "ColorModePermission") {
            for service in PermissionService.allCases {
                if let value = trimmedChild(modes, service.rawValue),
                   let permission = FeaturePermission(rawValue: value) {
                    out.access[service] = permission
                }
            }
        }
        return out
    }

    private static func element(_ el: XMLElement, _ name: String) -> XMLElement? {
        ((try? el.nodes(forXPath: ".//*[local-name()='\(name)']").first) ?? nil) as? XMLElement
    }

    private static func trimmedChild(_ el: XMLElement, _ name: String) -> String? {
        let v = child(el, name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// The device writes these as "true"/"false"; some models answer "1"/"0".
    private static func bool(_ s: String) -> Bool {
        s == "true" || s == "1"
    }
}
