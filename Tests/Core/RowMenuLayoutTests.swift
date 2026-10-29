import Testing
@testable import CorresCore

struct RowMenuLayoutTests {
    @Test func nothingSavedIsTheDefault() {
        let layout = RowMenuLayout(topRaw: "", listRaw: "")
        #expect(layout == .standard)
        #expect(layout.top == [.reply, .archive, .trash, .read])
        #expect(layout.list == [.flag, .snooze, .pin, .moveTo, .mute])
    }

    @Test func dashMeansChosenEmpty() {
        let layout = RowMenuLayout(topRaw: "-", listRaw: "-")
        #expect(layout.top.isEmpty)
        #expect(layout.list.isEmpty)
        #expect(layout.topRaw == "-")
        #expect(layout.listRaw == "-")
    }

    @Test func savedRoundTrips() {
        let layout = RowMenuLayout(top: [.archive, .flag], list: [.moveTo, .spam, .block])
        #expect(RowMenuLayout(topRaw: layout.topRaw, listRaw: layout.listRaw) == layout)
        #expect(layout.topRaw == "archive,flag")
    }

    @Test func unknownNamesAndRepeatsAreSkipped() {
        let layout = RowMenuLayout(topRaw: "archive,teleport,archive,trash", listRaw: "flag,,flag,someday,mute")
        #expect(layout.top == [.archive, .trash])
        #expect(layout.list == [.flag, .mute])
    }

    @Test func topRowKeepsToFourAndWhatFitsIt() {
        let layout = RowMenuLayout(topRaw: "moveTo,reply,spam,archive,trash,read,flag", listRaw: "-")
        #expect(layout.top == [.reply, .archive, .trash, .read])
    }

    @Test func listKeepsToItsLimit() {
        let all = RowMenuAction.allCases.map(\.rawValue).joined(separator: ",")
        let layout = RowMenuLayout(topRaw: "-", listRaw: all)
        #expect(layout.list.count == RowMenuLayout.listLimit)
        #expect(layout.list == Array(RowMenuAction.allCases.prefix(RowMenuLayout.listLimit)))
    }

    @Test func anActionOnTheTopRowIsLeftOutOfTheList() {
        // A custom top row with the default list: Flag shows once, on top.
        let layout = RowMenuLayout(topRaw: "flag,archive", listRaw: "")
        #expect(layout.top == [.flag, .archive])
        #expect(layout.list == [.snooze, .pin, .moveTo, .mute])
    }

    @Test func addingMovesBetweenRowAndList() {
        var layout = RowMenuLayout.standard
        layout.add(.flag, toTop: true)
        #expect(layout.top == [.reply, .archive, .trash, .read], "the top row is full")
        layout.top.removeLast()
        layout.add(.flag, toTop: true)
        #expect(layout.top == [.reply, .archive, .trash, .flag])
        #expect(!layout.list.contains(.flag))
        layout.add(.trash, toTop: false)
        #expect(!layout.top.contains(.trash))
        #expect(layout.list.last == .trash)
    }

    @Test func submenusAndDestructiveActionsNeverGoOnTop() {
        var layout = RowMenuLayout(top: [], list: [])
        for action in [RowMenuAction.moveTo, .reminder, .unsubscribe, .spam, .block] {
            #expect(!layout.canAdd(action, toTop: true))
            layout.add(action, toTop: true)
        }
        #expect(layout.top.isEmpty)
        #expect(RowMenuAction.allCases.filter(\.isDestructive) == [.spam, .block])
    }

    @Test func unusedIsEverythingElse() {
        let layout = RowMenuLayout.standard
        #expect(Set(layout.unused).isDisjoint(with: layout.top + layout.list))
        #expect(layout.unused.count + layout.top.count + layout.list.count == RowMenuAction.allCases.count)
    }
}
