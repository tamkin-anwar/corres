import Foundation

/// What a folder is for, so Corres knows where Sent, Trash and Archive are
/// on any server.
public enum FolderRole: String, Sendable, CaseIterable {
    case inbox, sent, drafts, trash, junk, archive, all, flagged
}

public struct Folder: Sendable, Equatable, Hashable {
    /// The server's name for it, as it must be sent back ("Sent Messages").
    public let path: String
    /// The separator between levels ("/" on iCloud, "." on some servers).
    public let delimiter: Character?
    /// The server's own flags for it, lowercased without the backslash
    /// ("sent", "noselect").
    public let attributes: Set<String>
    public let role: FolderRole?

    public init(path: String, delimiter: Character?, attributes: Set<String>) {
        self.path = path
        self.delimiter = delimiter
        let attrs = Set(attributes.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\\")) })
        self.attributes = attrs
        self.role = Folder.role(path: path, delimiter: delimiter, attributes: attrs)
    }

    /// Folders that hold no mail themselves (a parent in some servers).
    public var isSelectable: Bool { !attributes.contains("noselect") && !attributes.contains("nonexistent") }

    /// The last level of the path, for display ("Receipts" from
    /// "Archive/Receipts", "Entwürfe" from "Entw&APw-rfe").
    public var name: String {
        guard let delimiter, let last = path.split(separator: delimiter).last else { return ModifiedUTF7.decode(path) }
        return ModifiedUTF7.decode(String(last))
    }

    /// The whole path for display, its levels joined with " / " and each
    /// decoded ("Archiv / Entwürfe"). Commands still take `path`.
    public var displayPath: String {
        guard let delimiter else { return ModifiedUTF7.decode(path) }
        return path.split(separator: delimiter).map { ModifiedUTF7.decode(String($0)) }.joined(separator: " / ")
    }

    /// The server's SPECIAL-USE flag when it has one; otherwise the names
    /// servers use in practice: iCloud's "Sent Messages" and "Deleted
    /// Messages", Gmail-style "[Gmail]/Sent Mail", Outlook's "Deleted
    /// Items", Yahoo's "Bulk", and the same folders in the languages
    /// servers name them in ("Gesendet", "Corbeille", "已发送", "보낸메일함").
    static func role(path: String, delimiter: Character?, attributes: Set<String>) -> FolderRole? {
        if path.uppercased() == "INBOX" { return .inbox }
        let flagged: [(String, FolderRole)] = [("sent", .sent), ("drafts", .drafts), ("trash", .trash),
                                               ("junk", .junk), ("archive", .archive), ("all", .all),
                                               ("flagged", .flagged)]
        for (flag, role) in flagged where attributes.contains(flag) { return role }
        let raw = delimiter.flatMap { path.split(separator: $0).last.map(String.init) } ?? path
        let leaf = ModifiedUTF7.decode(raw).lowercased().precomposedStringWithCanonicalMapping
        for (role, set) in roleNames where set.contains(leaf) { return role }
        return nil
    }

    /// Folder names by role, in English and in the languages Corres is
    /// used in, as servers (Outlook, GMX, Orange, QQ, 163, Naver, Yahoo!
    /// JAPAN and others) name them when they don't flag them.
    static let roleNames: [FolderRole: Set<String>] = {
        let names: [FolderRole: [String]] = [
            .sent: ["sent", "sent messages", "sent mail", "sent items",
                    "gesendet", "gesendete elemente", "gesendete objekte", "gesendete nachrichten",
                    "envoyés", "envoyes", "éléments envoyés", "messages envoyés", "mails envoyés",
                    "enviados", "elementos enviados", "correo enviado", "mensajes enviados",
                    "itens enviados", "enviadas", "mensagens enviadas",
                    "posta inviata", "inviata", "verzonden", "verzonden items", "skickat", "wysłane",
                    "送信済み", "送信済みアイテム", "送信済みメール", "送信箱",
                    "已发送", "已發送", "已发送邮件", "已發送郵件", "已寄出", "寄件備份",
                    "보낸메일함", "보낸 메일함", "보낸편지함", "보낸 편지함",
                    "প্রেরিত", "পাঠানো", "পাঠানো মেইল", "প্রেরিত মেইল"],
            .drafts: ["drafts", "draft",
                      "entwürfe", "entwurf", "brouillons", "borradores", "rascunhos", "bozze", "concepten", "utkast", "szkice",
                      "下書き", "草稿", "草稿箱", "草稿夹", "임시보관함", "임시 보관함", "খসড়া"],
            .trash: ["trash", "deleted messages", "deleted items", "deleted", "bin",
                     "papierkorb", "gelöschte elemente", "gelöschte objekte", "gelöscht",
                     "corbeille", "éléments supprimés", "messages supprimés",
                     "papelera", "elementos eliminados", "eliminados",
                     "lixeira", "lixo", "itens excluídos", "excluídos", "itens eliminados",
                     "cestino", "posta eliminata", "prullenbak", "verwijderde items", "papperskorgen", "kosz",
                     "ゴミ箱", "ごみ箱", "削除済みアイテム", "削除済みメール",
                     "已删除", "已刪除", "已删除邮件", "已刪除郵件", "垃圾箱", "垃圾桶", "回收站",
                     "휴지통", "지운편지함", "지운 편지함",
                     "ট্র্যাশ", "ট্রাশ", "মুছে ফেলা", "আবর্জনা"],
            .junk: ["junk", "spam", "bulk", "bulk mail", "junk e-mail", "junk email",
                    "junk-e-mail", "unerwünscht", "courrier indésirable", "indésirables", "pourriel",
                    "correo no deseado", "no deseado", "lixo eletrônico", "lixo eletrónico", "posta indesiderata", "ongewenste e-mail",
                    "迷惑メール", "垃圾邮件", "垃圾郵件", "广告邮件", "스팸메일함", "스팸 메일함", "스팸편지함", "스팸 편지함", "স্প্যাম"],
            .archive: ["archive", "archives", "all mail",
                       "archiv", "archivo", "archivos", "arquivo", "arquivos", "archivio", "archief", "arkiv",
                       "アーカイブ", "归档", "歸檔", "存档", "封存", "보관함", "보관 메일함", "আর্কাইভ"],
        ]
        return names.mapValues { Set($0.map { $0.precomposedStringWithCanonicalMapping }) }
    }()
}

/// IMAP's modified UTF-7 (RFC 3501, 5.1.3), the way servers write folder
/// names that aren't plain ASCII: "Entw&APw-rfe" is "Entwürfe", "&U9dP4Xux-"
/// is "受信箱", "&-" is "&". Names are decoded for display only; commands
/// send back the server's own spelling.
public enum ModifiedUTF7 {
    public static func decode(_ name: String) -> String {
        guard name.contains("&") else { return name }
        var result = ""
        var rest = Substring(name)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            guard let dash = rest[afterAmp...].firstIndex(of: "-") else {
                // No closing "-": not modified UTF-7 (a server sending UTF-8).
                result += rest[amp...]
                return result
            }
            let encoded = rest[afterAmp..<dash]
            if encoded.isEmpty {
                result += "&"
            } else if let decoded = utf16(String(encoded)) {
                result += decoded
            } else {
                result += rest[amp...dash]
            }
            rest = rest[rest.index(after: dash)...]
        }
        result += rest
        return result
    }

    /// Modified base64 ("," for "/", no padding) of UTF-16 big-endian.
    private static func utf16(_ encoded: String) -> String? {
        var base64 = encoded.replacingOccurrences(of: ",", with: "/")
        guard base64.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }) else { return nil }
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        guard !units.isEmpty else { return nil }
        return String(decoding: units, as: UTF16.self)
    }
}

extension Array where Element == Folder {
    /// The folder for a role, preferring one the server labelled itself.
    public func folder(for role: FolderRole) -> Folder? {
        first { $0.role == role && $0.attributes.contains(role.rawValue) } ?? first { $0.role == role }
    }
}
