import Foundation

/// What the iPhone tells the Watch, and what the Watch asks the iPhone to
/// do, over WatchConnectivity. Compiled into the iPhone app and the Watch
/// app. The Watch keeps no account of its own: the iPhone sends a short
/// list (Needs You and Waiting, with the first lines of each), and does
/// whatever you choose on your wrist.
enum WatchLink {
    static let snapshotKey = "snapshot"
    static let commandKey = "command"

    struct Mail: Codable, Hashable, Identifiable, Sendable {
        /// "account|thread".
        let key: String
        let sender: String
        let subject: String
        let reason: String
        /// The first few hundred characters of the latest message.
        let preview: String
        let receivedAt: Date
        let isUnread: Bool
        var id: String { key }
    }

    struct Snapshot: Codable, Equatable, Sendable {
        var needsYou: [Mail]
        var waiting: [Mail]
        var isSample: Bool
        var updatedAt: Date
        /// How many in all: the lists stop at 25 and 10. Nil from a build
        /// before these were sent.
        var needsYouCount: Int?
        var waitingCount: Int?
        /// Needs You and Waiting are Corres Pro: without it the lists come
        /// empty and the Watch says how to start the trial. Nil from a
        /// build before this was sent.
        var isLocked: Bool? = nil

        static let empty = Snapshot(needsYou: [], waiting: [], isSample: false, updatedAt: .distantPast)
    }

    enum Command: Codable, Equatable, Sendable {
        case handled(key: String)
        case archive(key: String)
        case markRead(key: String)
        case reply(key: String, text: String)

        var key: String {
            switch self {
            case .handled(let key), .archive(let key), .markRead(let key), .reply(let key, _): key
            }
        }
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
