import Foundation
import Testing
@testable import CorresCore

struct DetectedItemsTests {
    @Test func flightNumbersAreRecognized() {
        #expect(DetectedItems.isFlightNumber("UA 1234"))
        #expect(DetectedItems.isFlightNumber("B6 615"))
        #expect(DetectedItems.isFlightNumber("DL123"))
        #expect(!DetectedItems.isFlightNumber("12 345"))
        #expect(!DetectedItems.isFlightNumber("1Z999AA10123456784"))
    }

    @Test func carriersComeFromTheNumbersFormat() {
        #expect(DetectedItems.carrier(forTracking: "1Z999AA10123456784") == .ups)
        #expect(DetectedItems.carrier(forTracking: "9400111899223197428490") == .usps)
        #expect(DetectedItems.carrier(forTracking: "EA123456789US") == .usps)
        #expect(DetectedItems.carrier(forTracking: "123456789012", context: "Your FedEx shipment is on its way") == .fedex)
        #expect(DetectedItems.carrier(forTracking: "1234567890", context: "Shipped with DHL Express") == .dhl)
        #expect(DetectedItems.carrier(forTracking: "TBA123456789000") == nil)
    }

    /// International postal numbers end in the sending country's code.
    @Test func postalNumbersByCountry() {
        let cases: [(String, DetectedItems.Carrier)] = [
            ("RR123456789GB", .royalMail), ("EE123456789CA", .canadaPost), ("LX123456789AU", .australiaPost),
            ("RA123456789JP", .japanPost), ("EM123456789IN", .indiaPost), ("LP123456789CN", .chinaPost),
            ("EA123456789US", .usps), ("RB123456789BD", .postal), ("CP123456789DE", .postal),
        ]
        for (number, carrier) in cases { #expect(DetectedItems.carrier(forTracking: number) == carrier, "\(number)") }
        #expect(DetectedItems.trackingURL(for: "RR123456789GB")?.host == "www.royalmail.com")
        #expect(DetectedItems.trackingURL(for: "RB123456789BD")?.absoluteString == "https://t.17track.net/en#nums=RB123456789BD")
        #expect(DetectedItems.trackingURL(for: "LP123456789CN")?.host == "t.17track.net")
    }

    /// A plain run of digits is FedEx's or DHL's only when the email says so.
    @Test func plainNumbersNeedTheCarrierNamed() {
        #expect(DetectedItems.carrier(forTracking: "123456789012") == nil)
        #expect(DetectedItems.carrier(forTracking: "1234567890") == nil)
        #expect(DetectedItems.carrier(forTracking: "1234567890", context: "Your Delhivery order") == nil)
        #expect(DetectedItems.destination(forMisc: "123456789012")?.host == "www.google.com")
        #expect(DetectedItems.destination(forMisc: "123456789012", context: "FedEx tracking")?.host == "www.fedex.com")
    }

    @Test func carrierNamesFromTheEmail() {
        #expect(DetectedItems.carrierName(in: "Your parcel is out for delivery with UPS today") == "UPS")
        #expect(DetectedItems.carrierName(in: "Mobile top-ups and follow-ups are now easier") == nil)
        #expect(DetectedItems.carrierName(in: "Shipped via USPS Priority") == "USPS")
        #expect(DetectedItems.carrierName(in: "Your Evri parcel is on its way") == "Evri")
        #expect(DetectedItems.carrierName(in: "ヤマト運輸がお届けします") == "Yamato")
        #expect(DetectedItems.carrierName(in: "Delivered by Pathao") == "Pathao")
        #expect(DetectedItems.carrierName(in: "CJ대한통운 배송 시작") == "CJ Logistics")
        #expect(DetectedItems.carrierName(in: "顺丰速运已发货") == "SF Express")
        #expect(DetectedItems.carrierName(in: "Out for delivery", senderEmail: "noreply@notifications.canadapost.ca") == "Canada Post")
        #expect(DetectedItems.carrierName(in: "Out for delivery", senderEmail: "track@dpdlocal.co.uk") == "DPD")
        #expect(DetectedItems.carrierName(in: "Out for delivery", senderEmail: "news@groups.com") == nil)
    }

    @Test func tappedItemsGoSomewhereUseful() {
        #expect(DetectedItems.destination(forMisc: "1Z999AA10123456784")?.absoluteString
                == "https://www.ups.com/track?tracknum=1Z999AA10123456784")
        #expect(DetectedItems.destination(forMisc: "UA 1234")?.absoluteString == "https://flightaware.com/live/flight/UA1234")
        // Unknown carrier: a search for the number's tracking.
        #expect(DetectedItems.destination(forMisc: "TBA123456789000")?.absoluteString.contains("tracking") == true)
    }
}
