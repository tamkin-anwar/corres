import Foundation

/// Where a tapped flight or tracking number in an email goes. iOS finds
/// both in the text but labels them only "misc", so the text itself says
/// which it is: a flight's live status, a carrier's own tracking page when
/// the number's format names the carrier, otherwise a web search, which
/// shows most carriers' tracking.
public enum DetectedItems {
    public enum Carrier: String, Sendable {
        case ups, usps, fedex, dhl
        case royalMail, canadaPost, australiaPost, japanPost, indiaPost, chinaPost
        /// Another postal service's international number: 17TRACK follows
        /// all of them.
        case postal
    }

    /// An airline code and flight number: "UA 1234", "B6 615", "DL123".
    public static func isFlightNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Two-character airline code with at least one letter, then 1–4 digits.
        return trimmed.patternRange(#"^(?=[A-Z0-9]{0,1}[A-Z])[A-Z0-9]{2}\s?\d{1,4}$"#) != nil
    }

    /// The carrier a tracking number belongs to, when its format is
    /// distinctive enough to say. International postal numbers
    /// ("RR123456789GB") end in the sending country's code. Plain runs of
    /// 10, 12 or 15 digits are FedEx's or DHL's only when the email
    /// (`context`) names that carrier: the same lengths are order numbers
    /// and other carriers' numbers around the world.
    public static func carrier(forTracking text: String, context: String? = nil) -> Carrier? {
        let number = text.uppercased().filter { $0.isLetter || $0.isNumber }
        let digits = number.allSatisfy(\.isNumber)
        if number.patternRange(#"^1Z[0-9A-Z]{16}$"#) != nil { return .ups }
        if digits, [20, 22].contains(number.count), number.patternRange(#"^9[2-5]"#) != nil { return .usps }
        if number.patternRange(#"^[A-Z]{2}\d{9}[A-Z]{2}$"#) != nil {
            switch number.suffix(2) {
            case "US": return .usps
            case "GB": return .royalMail
            case "CA": return .canadaPost
            case "AU": return .australiaPost
            case "JP": return .japanPost
            case "IN": return .indiaPost
            case "CN": return .chinaPost
            default: return .postal
            }
        }
        let names = context.map { $0.lowercased() } ?? ""
        if digits, [12, 15].contains(number.count), names.patternRange(#"\bfed ?ex\b"#) != nil { return .fedex }
        if digits, number.count == 10, names.patternRange(#"\bdhl\b"#) != nil { return .dhl }
        return nil
    }

    public static func trackingURL(for text: String, context: String? = nil) -> URL? {
        let number = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard let carrier = carrier(forTracking: text, context: context) else { return nil }
        let japanese = Locale.current.language.languageCode?.identifier == "ja"
        let link: String = switch carrier {
        case .ups: "https://www.ups.com/track?tracknum=\(number)"
        case .usps: "https://tools.usps.com/go/TrackConfirmAction?tLabels=\(number)"
        case .fedex: "https://www.fedex.com/fedextrack/?trknbr=\(number)"
        case .dhl: "https://www.dhl.com/global-en/home/tracking/tracking-express.html?submit=1&tracking-id=\(number)"
        case .royalMail: "https://www.royalmail.com/track-your-item#/tracking-results/\(number)"
        case .canadaPost: "https://www.canadapost-postescanada.ca/track-reperage/en#/search?searchFor=\(number)"
        case .australiaPost: "https://auspost.com.au/mypost/track/details/\(number)"
        case .japanPost: "https://trackings.post.japanpost.jp/services/srv/search/direct?reqCodeNo1=\(number)&searchKind=S002&locale=\(japanese ? "ja" : "en")"
        // India Post and China Post have no tracking page that takes the
        // number in its address; 17TRACK follows both.
        case .indiaPost, .chinaPost, .postal: "https://t.17track.net/en#nums=\(number)"
        }
        return URL(string: link)
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
    /// tracking page, or a search for whatever else it is. `context` is
    /// the email's text, which says which carrier a plain number is with.
    public static func destination(forMisc text: String, context: String? = nil) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isFlightNumber(trimmed) { return flightStatusURL(for: trimmed) }
        if let tracking = trackingURL(for: trimmed, context: context) { return tracking }
        if trimmed.count >= 8, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " }),
           trimmed.contains(where: \.isNumber) {
            return searchURL("\(trimmed) tracking")
        }
        return searchURL(trimmed)
    }

    // MARK: Carriers by name

    /// Delivery companies by the names emails use and the domains they
    /// send from, in the places Corres is used: the US, Canada, the UK and
    /// Europe, Australia, Japan, Korea, China, India and Bangladesh.
    static let carriers: [(name: String, words: String, domains: [String])] = [
        ("USPS", #"\busps\b"#, ["usps.com", "usps.gov"]),
        ("UPS", #"(?-i:(?<![-\w])UPS\b)|\bups\.com\b"#, ["ups.com"]),
        ("FedEx", #"\bfed ?ex\b"#, ["fedex.com"]),
        ("DHL", #"\bdhl\b"#, ["dhl.com", "dhl.de", "dhl.co.uk"]),
        ("Royal Mail", #"\broyal mail\b"#, ["royalmail.com", "royalmail.co.uk"]),
        ("Parcelforce", #"\bparcelforce\b"#, ["parcelforce.com", "parcelforce.co.uk"]),
        ("Evri", #"\bevri\b"#, ["evri.com", "myhermes.co.uk"]),
        ("DPD", #"\bdpd\b"#, ["dpd.co.uk", "dpd.com", "dpd.de", "dpdlocal.co.uk"]),
        ("Yodel", #"\byodel\b"#, ["yodel.co.uk"]),
        ("Canada Post", #"\bcanada post\b|\bpostes canada\b"#, ["canadapost.ca", "canadapost-postescanada.ca", "postescanada.ca"]),
        ("Purolator", #"\bpurolator\b"#, ["purolator.com"]),
        ("Australia Post", #"\baustralia post\b|\bauspost\b"#, ["auspost.com.au"]),
        ("StarTrack", #"\bstar ?track\b"#, ["startrack.com.au"]),
        ("Japan Post", #"\bjapan post\b|日本郵便|ゆうパック|ゆうパケット"#, ["post.japanpost.jp", "japanpost.jp"]),
        ("Yamato", #"\byamato\b|ヤマト運輸|クロネコ"#, ["kuronekoyamato.co.jp", "yamato-hd.co.jp"]),
        ("Sagawa", #"\bsagawa\b|佐川急便"#, ["sagawa-exp.co.jp"]),
        ("Delhivery", #"\bdelhivery\b"#, ["delhivery.com"]),
        ("Blue Dart", #"\bblue ?dart\b"#, ["bluedart.com"]),
        ("Ekart", #"\bekart\b"#, ["ekartlogistics.com", "ekart.com"]),
        ("India Post", #"\bindia post\b"#, ["indiapost.gov.in"]),
        ("Pathao", #"\bpathao\b"#, ["pathao.com"]),
        ("RedX", #"\bredx\b"#, ["redx.com.bd"]),
        ("Steadfast", #"\bsteadfast courier\b"#, ["steadfast.com.bd"]),
        ("Sundarban", #"\bsundarban courier\b"#, ["sundarbancourierltd.com"]),
        ("SF Express", #"\bsf express\b|顺丰|順豐"#, ["sf-express.com", "sf-international.com"]),
        ("CJ Logistics", #"\bcj logistics\b|cj대한통운|cj 대한통운"#, ["cjlogistics.com"]),
        ("Amazon", #"\bamazon logistics\b"#, []),
    ]

    /// The delivery company a shipping email is from or names: the
    /// sender's domain first ("ups.com"), then the email's words. Only
    /// "UPS" in capitals counts as UPS, so "top-ups" and "follow-ups" don't.
    public static func carrierName(in text: String, senderEmail: String? = nil) -> String? {
        if let host = senderEmail?.split(separator: "@").last.map({ $0.lowercased() }) {
            for carrier in carriers where carrier.domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return carrier.name
            }
        }
        for carrier in carriers where text.patternRange(carrier.words, caseInsensitive: true) != nil {
            return carrier.name
        }
        return nil
    }
}
