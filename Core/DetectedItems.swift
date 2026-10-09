import Foundation

/// Where a tapped flight or tracking number in an email goes. iOS finds
/// both in the text but labels them only "misc", so the text itself says
/// which it is: a flight's live status, a carrier's own tracking page when
/// the number's format names the carrier, otherwise a web search, which
/// shows most carriers' tracking.
public enum DetectedItems {
    public enum Carrier: String, Sendable { case ups, usps, fedex, dhl }

    /// An airline code and flight number: "UA 1234", "B6 615", "DL123".
    public static func isFlightNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Two-character airline code with at least one letter, then 1–4 digits.
        return trimmed.range(of: #"^(?=[A-Z0-9]{0,1}[A-Z])[A-Z0-9]{2}\s?\d{1,4}$"#, options: .regularExpression) != nil
    }

    /// The carrier a tracking number's format belongs to, when it's
    /// distinctive enough to say.
    public static func carrier(forTracking text: String) -> Carrier? {
        let number = text.uppercased().filter { $0.isLetter || $0.isNumber }
        let digits = number.allSatisfy(\.isNumber)
        if number.range(of: #"^1Z[0-9A-Z]{16}$"#, options: .regularExpression) != nil { return .ups }
        if digits, [20, 22].contains(number.count), number.range(of: #"^9[2-5]"#, options: .regularExpression) != nil { return .usps }
        if number.range(of: #"^[A-Z]{2}\d{9}US$"#, options: .regularExpression) != nil { return .usps }
        if digits, [12, 15].contains(number.count) { return .fedex }
        if digits, number.count == 10 { return .dhl }
        return nil
    }

    public static func trackingURL(for text: String) -> URL? {
        let number = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard let carrier = carrier(forTracking: text) else { return nil }
        let base: String = switch carrier {
        case .ups: "https://www.ups.com/track?tracknum="
        case .usps: "https://tools.usps.com/go/TrackConfirmAction?tLabels="
        case .fedex: "https://www.fedex.com/fedextrack/?trknbr="
        case .dhl: "https://www.dhl.com/global-en/home/tracking/tracking-express.html?submit=1&tracking-id="
        }
        return URL(string: base + number)
    }

    /// A flight's live status, by its airline code and number.
    public static func flightStatusURL(for text: String) -> URL? {
        let code = text.uppercased().filter { $0.isLetter || $0.isNumber }
        return URL(string: "https://flightaware.com/live/flight/\(code)")
    }

    /// A web search; search results show a status card for flights and
    /// most carriers' parcels.
    public static func searchURL(_ query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// Where a tapped "misc" item goes: a flight's status, a parcel's
    /// tracking page, or a search for whatever else it is.
    public static func destination(forMisc text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isFlightNumber(trimmed) { return flightStatusURL(for: trimmed) }
        if let tracking = trackingURL(for: trimmed) { return tracking }
        if trimmed.count >= 8, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " }),
           trimmed.contains(where: \.isNumber) {
            return searchURL("\(trimmed) tracking")
        }
        return searchURL(trimmed)
    }
}
