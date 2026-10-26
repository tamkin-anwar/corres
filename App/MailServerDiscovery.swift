import Foundation

/// Works out an email address's servers from the address alone, so adding
/// any account is an address and a password, nothing more. In order:
///
/// 1. Corres's own list of the common services, with whether each needs
///    an app password and where to make one.
/// 2. Addresses that belong with Corres's own sign-ins (Gmail, Outlook,
///    iCloud), including custom domains hosted by Google or Microsoft,
///    found from where the domain's mail goes (MX).
/// 3. The provider's own published settings (autoconfig), then the
///    public database Thunderbird keeps (ISPDB), by domain and by the
///    company the domain's mail is hosted with.
/// 4. The servers the domain announces in DNS (RFC 6186), then the usual
///    names (imap.example.com, mail.example.com).
///
/// Every candidate is proven by signing in before it's kept. Only the
/// domain ever leaves the iPhone during the search, never the address or
/// the password.
enum MailServerDiscovery {
    /// A service Corres knows: its servers, and how it signs apps in.
    struct Service: Sendable {
        let name: String
        let server: IMAPServer
        /// Needs a password made for apps, not the account's own.
        let appPassword: Bool
        let appPasswordURL: URL?
        /// What to do there, in the service's own words.
        let steps: [String]
    }

    enum Finding: Sendable {
        /// Use Corres's own sign-in for this provider instead.
        case useSignIn(MailProvider)
        /// A known service, or settings found for this domain, to prove by
        /// signing in. `service` is set when Corres knows it by name.
        case candidates([IMAPServer], service: Service?)
        /// Can't be added (Proton needs its Bridge app on a computer).
        case unsupported(String)
    }

    // MARK: Known services

    private static func smtp(_ host: String, _ port: Int) -> (String, Int, IMAPServer.SMTPSecurity) {
        (host, port, port == 465 ? .tls : .startTLS)
    }

    private static func service(_ name: String, imap: String, smtp host: String, port: Int = 465,
                                appPassword: Bool, url: String? = nil, steps: [String] = []) -> Service {
        let s = smtp(host, port)
        return Service(name: name, server: IMAPServer(imapHost: imap, smtpHost: s.0, smtpPort: s.1, smtpSecurity: s.2),
                       appPassword: appPassword, appPasswordURL: url.flatMap(URL.init(string:)), steps: steps)
    }

    static let yahoo = service("Yahoo Mail", imap: "imap.mail.yahoo.com", smtp: "smtp.mail.yahoo.com", appPassword: true,
                               url: "https://login.yahoo.com/account/security/app-passwords",
                               steps: [String(localized: "Open Yahoo Account Security below and sign in."), String(localized: "Choose Generate app password."),
                                       String(localized: "Name it Corres, then copy the password.")])
    static let aol = service("AOL Mail", imap: "imap.aol.com", smtp: "smtp.aol.com", appPassword: true,
                             url: "https://login.aol.com/account/security/app-passwords",
                             steps: [String(localized: "Open AOL Account Security below and sign in."), String(localized: "Choose Generate app password."),
                                     String(localized: "Name it Corres, then copy the password.")])
    static let fastmail = service("Fastmail", imap: "imap.fastmail.com", smtp: "smtp.fastmail.com", appPassword: true,
                                  url: "https://app.fastmail.com/settings/security/apps/new",
                                  steps: [String(localized: "Open Fastmail below and sign in."), String(localized: "Make a new app password with access to IMAP and SMTP."),
                                          String(localized: "Name it Corres, then copy the password.")])
    static let zoho = service("Zoho Mail", imap: "imap.zoho.com", smtp: "smtp.zoho.com", appPassword: true,
                              url: "https://accounts.zoho.com/home#security/app_password",
                              steps: [String(localized: "Open Zoho Accounts below and sign in."), String(localized: "Choose App Passwords, then Generate New Password."),
                                      String(localized: "Name it Corres, then copy the password.")])
    static let yandex = service("Yandex Mail", imap: "imap.yandex.com", smtp: "smtp.yandex.com", appPassword: true,
                                url: "https://id.yandex.com/security/app-passwords",
                                steps: [String(localized: "Open Yandex ID below and sign in."), String(localized: "Create an app password for Mail."),
                                        String(localized: "Copy the password.")])
    static let att = service("AT&T Mail", imap: "imap.mail.att.net", smtp: "smtp.mail.att.net", appPassword: true,
                             url: "https://www.att.com/acctmgmt/signin",
                             steps: [String(localized: "Open your AT&T account below and sign in."), String(localized: "Under Sign-in info, choose Secure mail key, then Add secure mail key."),
                                     String(localized: "Name it Corres, then copy the key.")])
    static let gmxCom = service("GMX", imap: "imap.gmx.com", smtp: "mail.gmx.com", port: 587, appPassword: false,
                                steps: [String(localized: "In GMX on the web, turn on IMAP access under Settings, POP3 & IMAP, if it's off.")])
    static let gmxNet = service("GMX", imap: "imap.gmx.net", smtp: "mail.gmx.net", port: 587, appPassword: false,
                                steps: [String(localized: "In GMX on the web, turn on IMAP access under Settings, POP3 & IMAP, if it's off.")])
    static let mailCom = service("Mail.com", imap: "imap.mail.com", smtp: "smtp.mail.com", port: 587, appPassword: false,
                                 steps: [String(localized: "In Mail.com on the web, turn on IMAP access under Settings, POP3 & IMAP, if it's off.")])
    // Asia's own services. Server names checked against each provider's
    // help pages and Thunderbird's ISPDB (October 2026).
    static let yahooJapan = service("Yahoo! JAPAN Mail", imap: "imap.mail.yahoo.co.jp", smtp: "smtp.mail.yahoo.co.jp", appPassword: false,
                                    steps: [String(localized: "In Yahoo! JAPAN Mail on the web, open Settings, then IMAP/POP/SMTP Access."),
                                            String(localized: "Allow access from services other than Yahoo! JAPAN, and set IMAP, POP and SMTP to Use."),
                                            String(localized: "If your Yahoo! JAPAN ID has no password yet, set one, then use it here.")])
    static let qq = service("QQ Mail", imap: "imap.qq.com", smtp: "smtp.qq.com", appPassword: true,
                            url: "https://wx.mail.qq.com/",
                            steps: [String(localized: "Open QQ Mail below and sign in."),
                                    String(localized: "In Settings, Account and Security, turn on IMAP/SMTP, then generate an authorization code."),
                                    String(localized: "Copy the 16-character code and use it as the password.")])
    private static func netEase(_ name: String, domain: String) -> Service {
        service(name, imap: "imap.\(domain)", smtp: "smtp.\(domain)", appPassword: true, url: "https://mail.\(domain)/",
                steps: [String(localized: "Open \(name) below and sign in."),
                        String(localized: "In Settings, POP3/SMTP/IMAP, turn on IMAP/SMTP, then add an authorization code."),
                        String(localized: "Copy the code and use it as the password. It's shown only once.")])
    }
    static let mail163 = netEase("163 Mail", domain: "163.com")
    static let mail126 = netEase("126 Mail", domain: "126.com")
    static let yeah = netEase("Yeah Mail", domain: "yeah.net")
    static let naver = service("Naver Mail", imap: "imap.naver.com", smtp: "smtp.naver.com", appPassword: true,
                               steps: [String(localized: "In Naver Mail on the web, open Settings, then POP3/IMAP Settings, and set IMAP/SMTP to Use."),
                                       String(localized: "In your Naver account's security settings, turn on 2-step verification and make an app password."),
                                       String(localized: "Copy the app password and use it here.")])

    static let known: [String: Service] = {
        var map: [String: Service] = [:]
        for d in ["yahoo.com", "ymail.com", "rocketmail.com", "yahoo.co.uk", "yahoo.ca", "yahoo.com.au", "yahoo.co.in",
                  "yahoo.fr", "yahoo.de", "yahoo.es", "yahoo.it"] { map[d] = yahoo }
        // Yahoo! JAPAN is its own company with its own servers.
        for d in ["yahoo.co.jp", "ymail.ne.jp"] { map[d] = yahooJapan }
        map["qq.com"] = qq
        map["163.com"] = mail163; map["126.com"] = mail126; map["yeah.net"] = yeah
        map["naver.com"] = naver
        for d in ["aol.com", "aim.com", "love.com", "games.com", "wow.com"] { map[d] = aol }
        for d in ["fastmail.com", "fastmail.fm", "fastmail.us", "fastmail.co.uk", "sent.com", "messagingengine.com"] { map[d] = fastmail }
        for d in ["zoho.com", "zohomail.com", "zoho.eu", "zoho.in"] { map[d] = zoho }
        for d in ["yandex.com", "yandex.ru"] { map[d] = yandex }
        map["gmx.com"] = gmxCom; map["gmx.us"] = gmxCom
        for d in ["gmx.net", "gmx.de", "gmx.at", "gmx.ch"] { map[d] = gmxNet }
        map["mail.com"] = mailCom
        for d in ["att.net", "sbcglobal.net", "bellsouth.net", "pacbell.net", "flash.net", "swbell.net", "ameritech.net", "prodigy.net", "wans.net", "nvbell.net", "snet.net"] { map[d] = att }
        return map
    }()

    static let gmailDomains: Set<String> = ["gmail.com", "googlemail.com"]
    static let outlookDomains: Set<String> = ["outlook.com", "hotmail.com", "live.com", "msn.com", "hotmail.co.uk", "outlook.co.uk", "live.co.uk"]
    static let icloudDomains: Set<String> = ["icloud.com", "me.com", "mac.com"]
    static let protonDomains: Set<String> = ["proton.me", "protonmail.com", "protonmail.ch", "pm.me"]

    // MARK: Finding

    static func find(for address: String) async -> Finding {
        let domain = address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        if gmailDomains.contains(domain) { return .useSignIn(.google) }
        if outlookDomains.contains(domain) { return .useSignIn(.microsoft) }
        if icloudDomains.contains(domain) { return .useSignIn(.icloud) }
        if protonDomains.contains(domain) { return .unsupported(protonNote) }
        if domain == "hey.com" { return .unsupported(String(localized: "HEY doesn't let other mail apps read its mail, so it can't be added to Corres.")) }
        if let service = known[domain] { return .candidates([service.server], service: service) }

        // A custom domain: where its mail goes says who hosts it.
        let mx = await mxHosts(domain)
        if mx.contains(where: { $0.hasSuffix("google.com") || $0.hasSuffix("googlemail.com") }) { return .useSignIn(.google) }
        if mx.contains(where: { $0.hasSuffix("outlook.com") || $0.hasSuffix("protection.outlook.com") }) { return .useSignIn(.microsoft) }
        if mx.contains(where: { $0.hasSuffix("icloud.com") || $0.hasSuffix("me.com") }) { return .useSignIn(.icloud) }
        if mx.contains(where: { $0.hasSuffix("protonmail.ch") }) { return .unsupported(protonNote) }
        let mxBase = mx.first.map(baseDomain)
        if let mxBase, let service = known[mxBase] { return .candidates([service.server], service: service) }
        if mx.contains(where: { $0.hasSuffix("messagingengine.com") }) { return .candidates([fastmail.server], service: fastmail) }
        if mx.contains(where: { $0.hasSuffix("zoho.com") || $0.hasSuffix("zoho.eu") }) { return .candidates([zoho.server], service: zoho) }

        // Published settings, all asked at once; the first good answer wins.
        var found: [IMAPServer] = []
        async let own = autoconfig("https://autoconfig.\(domain)/mail/config-v1.1.xml", address: address)
        async let wellKnown = autoconfig("https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml", address: address)
        async let ispdb = autoconfig("https://autoconfig.thunderbird.net/v1.1/\(domain)", address: address)
        async let ispdbHost = ispdbForHost(mxBase, address: address)
        async let srv = srvServer(domain)
        for candidate in [await own, await wellKnown, await ispdb, await ispdbHost, await srv] {
            if let candidate, !found.contains(candidate) { found.append(candidate) }
        }
        // And the names servers are usually given.
        for host in ["imap.\(domain)", "mail.\(domain)"] {
            let guess = IMAPServer(imapHost: host, smtpHost: host == "imap.\(domain)" ? "smtp.\(domain)" : host)
            if !found.contains(where: { $0.imapHost == guess.imapHost }) { found.append(guess) }
        }
        return .candidates(found, service: nil)
    }

    private static func ispdbForHost(_ base: String?, address: String) async -> IMAPServer? {
        guard let base else { return nil }
        return await autoconfig("https://autoconfig.thunderbird.net/v1.1/\(base)", address: address)
    }

    static var protonNote: String {
        String(localized: "Proton Mail can only be read by other apps through Proton Mail Bridge, which runs on a computer, so it can't be added on iPhone.")
    }

    /// example.co.uk from mx1.mail.example.co.uk; example.com from mx.example.com.
    static func baseDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel = ["co", "com", "net", "org", "ac", "gov", "edu"]
        let take = labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    // MARK: Lookups

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    /// DNS over HTTPS: iOS has no MX or SRV lookup of its own.
    private static func dns(_ name: String, type: String) async -> [String] {
        var components = URLComponents(string: "https://cloudflare-dns.com/dns-query")!
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "type", value: type)]
        var request = URLRequest(url: components.url!)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]] else { return [] }
        return answers.compactMap { $0["data"] as? String }
    }

    static func mxHosts(_ domain: String) async -> [String] {
        await dns(domain, type: "MX")
            .compactMap { record -> (Int, String)? in
                let parts = record.split(separator: " ")
                guard parts.count == 2, let priority = Int(parts[0]) else { return nil }
                return (priority, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased())
            }
            .sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// _imaps._tcp and _submission._tcp / _submissions._tcp (RFC 6186, 8314).
    private static func srvServer(_ domain: String) async -> IMAPServer? {
        func target(_ records: [String]) -> (host: String, port: Int)? {
            records.compactMap { record -> (Int, String, Int)? in
                let parts = record.split(separator: " ")
                guard parts.count == 4, let priority = Int(parts[0]), let port = Int(parts[2]) else { return nil }
                let host = parts[3].trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return host.isEmpty ? nil : (priority, host, port)
            }.sorted { $0.0 < $1.0 }.first.map { ($0.1, $0.2) }
        }
        async let imaps = dns("_imaps._tcp.\(domain)", type: "SRV")
        async let submissions = dns("_submissions._tcp.\(domain)", type: "SRV")
        async let submission = dns("_submission._tcp.\(domain)", type: "SRV")
        guard let imap = target(await imaps) else { return nil }
        if let out = target(await submissions) {
            return IMAPServer(imapHost: imap.host, imapPort: imap.port, smtpHost: out.host, smtpPort: out.port, smtpSecurity: .tls)
        }
        let out = target(await submission) ?? (imap.host, 587)
        return IMAPServer(imapHost: imap.host, imapPort: imap.port, smtpHost: out.host, smtpPort: out.port, smtpSecurity: .startTLS)
    }

    /// A Thunderbird-format autoconfig file: its IMAP server over TLS and
    /// its SMTP server. Corres signs in to IMAP over TLS only.
    static func autoconfig(_ url: String, address: String) async -> IMAPServer? {
        guard let url = URL(string: url), let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseAutoconfig(data, address: address)
    }

    static func parseAutoconfig(_ data: Data, address: String) -> IMAPServer? {
        let parser = AutoconfigParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }
        guard let imap = parser.servers.first(where: { $0.kind == "incoming" && $0.type == "imap" && $0.socket == "SSL" }),
              let smtp = parser.servers.first(where: { $0.kind == "outgoing" && $0.type == "smtp" && $0.socket != "plain" }) else { return nil }
        let local = address.split(separator: "@").first.map(String.init) ?? address
        let domain = address.split(separator: "@").last.map(String.init) ?? ""
        func fill(_ text: String) -> String {
            text.replacingOccurrences(of: "%EMAILADDRESS%", with: address)
                .replacingOccurrences(of: "%EMAILLOCALPART%", with: local)
                .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
        }
        let username = fill(imap.username)
        return IMAPServer(imapHost: fill(imap.host), imapPort: imap.port ?? 993, smtpHost: fill(smtp.host),
                          smtpPort: smtp.port ?? (smtp.socket == "SSL" ? 465 : 587),
                          smtpSecurity: smtp.socket == "SSL" ? .tls : .startTLS,
                          username: username.isEmpty || username.lowercased() == address.lowercased() ? nil : username)
    }

    private final class AutoconfigParser: NSObject, XMLParserDelegate {
        struct Server { var kind: String; var type: String; var host = ""; var port: Int?; var socket = ""; var username = "" }
        var servers: [Server] = []
        private var current: Server?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "incomingServer" { current = Server(kind: "incoming", type: attributes["type"] ?? "") }
            if name == "outgoingServer" { current = Server(kind: "outgoing", type: attributes["type"] ?? "") }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "hostname": current?.host = value.lowercased()
            case "port": current?.port = Int(value)
            case "socketType": current?.socket = value
            case "username": current?.username = value
            case "incomingServer", "outgoingServer":
                if let current, !current.host.isEmpty { servers.append(current) }
                current = nil
            default: break
            }
        }
    }
}
