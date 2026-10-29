import Foundation
import Testing
@testable import CorresCore

/// `logKind` goes into public log lines, so it must never carry an
/// error's text: only its type, case, numbers, domain and code.
struct ErrorLogKindTests {
    enum Sample: Error {
        case refused(statusCode: Int, message: String)
        case badResponse(statusCode: Int)
        case notSignedIn
        case failed(String)
    }

    struct Described: Error, CustomStringConvertible {
        var description: String { "mailbox maya@example.com is full" }
    }

    enum DescribedCase: Error, CustomStringConvertible {
        case full
        var description: String { "maya@example.com: full" }
    }

    @Test func keepsCaseAndNumbersButNotText() {
        let kind = Sample.refused(statusCode: 550, message: "No such user maya@example.com").logKind
        #expect(kind.contains("Sample.refused"))
        #expect(kind.contains("550"))
        #expect(!kind.contains("maya"))
        #expect(!kind.contains("No such user"))
    }

    @Test func simpleCases() {
        #expect(Sample.notSignedIn.logKind.contains("Sample.notSignedIn"))
        #expect(Sample.badResponse(statusCode: 401).logKind.contains("401"))
        #expect(!Sample.failed("subject: Lisbon trip").logKind.contains("Lisbon"))
    }

    @Test func customDescriptionsStayOut() {
        #expect(!Described().logKind.contains("maya"))
        #expect(!DescribedCase.full.logKind.contains("maya"))
    }

    @Test func foundationErrorsKeepDomainAndCode() {
        let kind = URLError(.notConnectedToInternet).logKind
        #expect(kind.contains("NSURLErrorDomain"))
        #expect(kind.contains("-1009"))
    }
}
