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
        #expect(DetectedItems.carrier(forTracking: "123456789012") == .fedex)
        #expect(DetectedItems.carrier(forTracking: "1234567890") == .dhl)
        #expect(DetectedItems.carrier(forTracking: "TBA123456789000") == nil)
    }

    @Test func tappedItemsGoSomewhereUseful() {
        #expect(DetectedItems.destination(forMisc: "1Z999AA10123456784")?.absoluteString
                == "https://www.ups.com/track?tracknum=1Z999AA10123456784")
        #expect(DetectedItems.destination(forMisc: "UA 1234")?.absoluteString == "https://flightaware.com/live/flight/UA1234")
        // Unknown carrier: a search for the number's tracking.
        #expect(DetectedItems.destination(forMisc: "TBA123456789000")?.absoluteString.contains("tracking") == true)
    }
}
