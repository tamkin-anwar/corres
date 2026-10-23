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
