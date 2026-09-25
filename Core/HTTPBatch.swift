import Foundation

/// Google's `multipart/mixed` batch format: many API calls in one HTTP
/// request, one nested HTTP response per call back. Sync uses it to fetch
/// 50 messages per round trip instead of one, the single largest cost of a
/// first sync. Pure string handling with no networking, so it's unit-tested
/// directly.
public enum HTTPBatch {
    public struct Part: Equatable, Sendable {
        public let status: Int
        public let body: Data
    }

    /// `paths` are request paths like `/gmail/v1/users/me/messages/ID?format=metadata`,
    /// each sent as a GET. Part `n` carries `Content-ID: <item-n>` so the
    /// responses can be matched back to requests regardless of order.
    public static func body(paths: [String], boundary: String) -> Data {
        var text = ""
        for (index, path) in paths.enumerated() {
            text += "--\(boundary)\r\n"
            text += "Content-Type: application/http\r\n"
            text += "Content-ID: <item-\(index)>\r\n\r\n"
            text += "GET \(path)\r\n\r\n"
        }
        text += "--\(boundary)--\r\n"
        return Data(text.utf8)
    }

    public static func boundary(fromContentType contentType: String) -> String? {
        for parameter in contentType.split(separator: ";") {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            return String(trimmed.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// Keyed by request index. A part that can't be parsed is simply
    /// absent, and the caller treats that request as failed.
    public static func parse(_ data: Data, boundary: String) -> [Int: Part] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [Int: Part] = [:]
        for rawPart in text.components(separatedBy: "--\(boundary)") {
            let part = rawPart.replacingOccurrences(of: "\r\n", with: "\n")
            guard let contentIDLine = part.split(separator: "\n").first(where: { $0.lowercased().hasPrefix("content-id:") }),
                  let index = Int(contentIDLine.components(separatedBy: "item-").last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "> \t")) ?? ""),
                  let statusRange = part.range(of: "HTTP/1.1 ") else { continue }
            let afterStatusLine = part[statusRange.upperBound...]
            guard let status = Int(afterStatusLine.prefix(3)) else { continue }
            guard let headerEnd = afterStatusLine.range(of: "\n\n") else {
                result[index] = Part(status: status, body: Data())
                continue
            }
            let body = afterStatusLine[headerEnd.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[index] = Part(status: status, body: Data(body.utf8))
        }
        return result
    }
}
