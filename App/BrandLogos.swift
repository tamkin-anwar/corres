import Foundation
import Observation

/// Company logos beside companies' mail, as Gmail and Mail show them, the
/// private way. The logo is the one the company publishes for email (BIMI),
/// and only one backed by a mark certificate, so a lookalike domain can't
/// borrow a bank's. Corres's logo relay fetches it (Server/logo-relay): the
/// company sees that server, never the person reading, and the relay is
/// sent a domain, never an address or anything from an email. Kept on this
/// device afterwards; Settings › Private by Design can turn them off.
@MainActor
final class BrandLogos {
    static let shared = BrandLogos()

    static let enabledKey = "corres.companyLogos"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// One domain's logo, watched on its own: a logo arriving redraws the
    /// avatars for that company, not every avatar on screen.
    @MainActor @Observable
    fileprivate final class Slot {
        var image: PlatformImage?
    }

    /// Logos ready to draw, by domain.
    private var slots: [String: Slot] = [:]
    private var checked: Set<String> = []
    private var waiting: [String] = []
    private var running = 0

    private func slot(_ domain: String) -> Slot {
        if let slot = slots[domain] { return slot }
        let slot = Slot()
        slots[domain] = slot
        return slot
    }

    nonisolated private static let endpoint = URL(string: "https://us-central1-corres-509320.cloudfunctions.net/corres-logos")!
    /// People's own addresses: a Gmail or iCloud logo beside a friend's
    /// name would say something untrue.
    private static let personal: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com",
        "mac.com", "yahoo.com", "ymail.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.de",
        "web.de", "mail.com", "zoho.com", "fastmail.com", "hey.com", "qq.com", "163.com", "naver.com", "yandex.ru",
    ]
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    nonisolated private static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("CompanyLogos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The company's logo for this sender, when there is one and it's
    /// here; asked for in the background otherwise, and drawn once it
    /// arrives.
    func logo(for email: String) -> PlatformImage? {
        guard Self.isEnabled, let domain = Self.domain(of: email) else { return nil }
        if let image = slot(domain).image { return image }
        if checked.insert(domain).inserted {
            waiting.append(domain)
            pump()
        }
        return nil
    }

    static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ">"))).lowercased()
        guard domain.contains("."), !personal.contains(domain) else { return nil }
        return domain
    }

    /// Three at a time, so a screen of new senders doesn't open twenty
    /// connections at once.
    private func pump() {
        while running < 3, !waiting.isEmpty {
            let domain = waiting.removeFirst()
            running += 1
            Task {
                let image = await Self.load(domain)
                running -= 1
                if let image { slot(domain).image = image }
                pump()
            }
        }
    }

    /// From this device when it was fetched lately (a logo for a month, a
    /// "none" for a week), otherwise from the relay.
    nonisolated private static func load(_ domain: String) async -> PlatformImage? {
        guard let folder else { return nil }
        let file = folder.appendingPathComponent(domain + ".png")
        let none = folder.appendingPathComponent(domain + ".none")
        let manager = FileManager.default
        if let date = (try? manager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           date.timeIntervalSinceNow > -30 * 86_400, let data = try? Data(contentsOf: file) {
            return PlatformImage(data: data)
        }
        if let date = (try? manager.attributesOfItem(atPath: none.path))?[.modificationDate] as? Date,
           date.timeIntervalSinceNow > -7 * 86_400 {
            return nil
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["domain": domain])
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 404 {
            manager.createFile(atPath: none.path, contents: Data())
            return nil
        }
        guard status == 200, let image = PlatformImage(data: data) else { return nil }
        try? data.write(to: file, options: .atomic)
        return image
    }

    /// Settings: logos off, and the ones kept on this device forgotten.
    func forgetAll() {
        for slot in slots.values { slot.image = nil }
        checked = []
        waiting = []
        if let folder = Self.folder { try? FileManager.default.removeItem(at: folder) }
    }
}
