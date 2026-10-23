import Foundation
import Testing
@testable import CorresCore

struct ServerRulePlanTests {
    typealias Plan = ServerRulePlan

    @Test func newRuleIsCreated() {
        let wanted = [Plan.Wanted(ruleID: "a", signature: "s1", keys: ["k1"])]
        #expect(Plan.removals(wanted: wanted, kept: [:]).isEmpty)
        #expect(Plan.additions(wanted: wanted, kept: [:], existing: []) == [.create(ruleID: "a", signature: "s1")])
    }

    @Test func unchangedRuleIsLeftAlone() {
        let wanted = [Plan.Wanted(ruleID: "a", signature: "s1", keys: ["k1"])]
        let kept = ["a": Plan.Entry(id: "f1", signature: "s1")]
        #expect(Plan.removals(wanted: wanted, kept: kept).isEmpty)
        #expect(Plan.additions(wanted: wanted, kept: kept, existing: []).isEmpty)
    }

    @Test func changedRuleIsReplaced() {
        let wanted = [Plan.Wanted(ruleID: "a", signature: "s2", keys: ["k2"])]
        let kept = ["a": Plan.Entry(id: "f1", signature: "s1")]
        #expect(Plan.removals(wanted: wanted, kept: kept) == [.remove(ruleID: "a", id: "f1")])
        // After the removal, nothing is kept for it: made again.
        #expect(Plan.additions(wanted: wanted, kept: [:], existing: []) == [.create(ruleID: "a", signature: "s2")])
    }

    @Test func deletedOrOffRuleIsRemoved() {
        let kept = ["a": Plan.Entry(id: "f1", signature: "s1"), "b": Plan.Entry(id: "f2", signature: "s2")]
        let wanted = [Plan.Wanted(ruleID: "b", signature: "s2", keys: [])]
        #expect(Plan.removals(wanted: wanted, kept: kept) == [.remove(ruleID: "a", id: "f1")])
    }

    @Test func anotherDevicesCopyIsAdoptedNotDuplicated() {
        let wanted = [Plan.Wanted(ruleID: "a", signature: "s1", keys: ["k1", "k1-no-tab"])]
        let existing = [Plan.Existing(id: "mine", key: "other"), Plan.Existing(id: "theirs", key: "k1-no-tab")]
        #expect(Plan.additions(wanted: wanted, kept: [:], existing: existing) == [.adopt(ruleID: "a", id: "theirs", signature: "s1")])
    }

    @Test func oneExistingFilterIsAdoptedOnce() {
        let wanted = [Plan.Wanted(ruleID: "a", signature: "s", keys: ["k"]), Plan.Wanted(ruleID: "b", signature: "s", keys: ["k"])]
        let existing = [Plan.Existing(id: "f", key: "k")]
        #expect(Plan.additions(wanted: wanted, kept: [:], existing: existing)
                == [.adopt(ruleID: "a", id: "f", signature: "s"), .create(ruleID: "b", signature: "s")])
    }

    @Test func gmailKeyIgnoresLabelOrder() {
        #expect(Plan.gmailKey(query: "from:a", add: ["STARRED", "CATEGORY_UPDATES"], remove: ["UNREAD"])
                == Plan.gmailKey(query: "from:a", add: ["CATEGORY_UPDATES", "STARRED"], remove: ["UNREAD"]))
    }
}
