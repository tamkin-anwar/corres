import Foundation
import Testing
@testable import CorresCore

struct SyncMergeTests {
    private func data(_ items: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) }
    private func ids(_ data: Data?) -> [String] {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []).compactMap { $0["id"] as? String }
    }

    @Test func addedOnBothIsKept() {
        let remote = data([["id": "a"], ["id": "b"]])
        let local = data([["id": "a"], ["id": "c"]])
        #expect(ids(SyncMerge.list(local: local, remote: remote, removed: [])) == ["a", "b", "c"])
    }

    @Test func deletedIsNotBroughtBack() {
        let remote = data([["id": "a"]])
        let local = data([["id": "a"], ["id": "b"]])
        #expect(ids(SyncMerge.list(local: local, remote: remote, removed: ["b"])) == ["a"])
        #expect(ids(SyncMerge.list(local: nil, remote: data([["id": "a"], ["id": "b"]]), removed: ["a"])) == ["b"])
    }

    @Test func nothingNewKeepsICloudsBytes() {
        let remote = data([["id": "a", "text": "x"]])
        let local = data([["id": "a", "text": "older"]])
        #expect(SyncMerge.list(local: local, remote: remote, removed: []) == remote)
    }

    @Test func notAListOfItemsIsLeftAlone() {
        #expect(SyncMerge.list(local: nil, remote: Data("{\"a\":1}".utf8), removed: []) == nil)
    }
}

struct SyncMergeSetTests {
    private let day: TimeInterval = 86_400
    private func token(_ s: String) -> String { "vip:" + s }

    @Test func vipsFromBothDevicesAreKept() {
        #expect(SyncMerge.strings(local: ["a"], remote: ["b"], added: [:], removed: [:], token: token) == ["a", "b"])
    }

    @Test func removedVIPStaysRemovedUntilAddedAgain() {
        let now = Date.now
        #expect(SyncMerge.strings(local: ["a"], remote: [], added: [:], removed: ["vip:a": now], token: token).isEmpty)
        #expect(SyncMerge.strings(local: ["a"], remote: [], added: ["vip:a": now], removed: ["vip:a": now.addingTimeInterval(-day)], token: token) == ["a"])
    }

    @Test func unmutedStaysUnmutedButAMuteAfterwardHolds() {
        let now = Date.now
        let unmuted = ["muted:x": now]
        #expect(SyncMerge.dated(local: [:], remote: ["x": now.addingTimeInterval(-day)], removed: unmuted, token: { "muted:" + $0 }).isEmpty)
        #expect(SyncMerge.dated(local: ["x": now.addingTimeInterval(day)], remote: [:], removed: unmuted, token: { "muted:" + $0 }).count == 1)
    }
}
