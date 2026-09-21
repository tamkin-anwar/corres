import Foundation

public enum SampleCorrespondence {
    public static func make(now: Date) -> [Correspondence] {
        let records: [(String, String, String, String, String, Attention, Int, Int?)] = [
            ("Maya Chen", "Atelier North", "The next chapter", "Your approval on the final direction is the last piece.", "Maya asked you to approve the creative direction before tomorrow's review.", .needsYou, 12, 20),
            ("Oliver Grant", "Fieldwork", "A moment before we move forward", "Two options for the launch. One decision to make.", "Oliver is waiting for your choice between the two launch approaches.", .needsYou, 38, nil),
            ("Sofia Laurent", "Maison Studio", "A place at the table", "Could you confirm Thursday's conversation?", "Sofia requested a meeting confirmation within the next day.", .needsYou, 64, 8),
            ("James Okafor", "Common Ground", "Partnership proposal", "I will send the revised scope once our team has reviewed it.", "James committed to sending a revised scope. Your last reply needs no action.", .waiting, 140, nil),
            ("Emma Park", "Form & Function", "The material samples", "Our workshop is preparing the samples you requested.", "You asked Emma for samples. She is arranging delivery.", .waiting, 240, nil),
            ("The Editorial", "Collected", "A little perspective", "This week's reading, collected in one place.", "A reading digest with no request addressed to you.", .quiet, 360, nil)
        ]
        return records.enumerated().map { index, row in
            Correspondence(
                id: ThreadID(account: "sample", providerID: "sample-\(index)"),
                sender: row.0, organization: row.1, subject: row.2, excerpt: row.3,
                body: "Hello,\n\n\(row.3)\n\nWe have taken time to consider the details and would appreciate your perspective. Everything you need for this conversation is here.\n\nWarmly,\n\(row.0)",
                receivedAt: now.addingTimeInterval(Double(-row.6 * 60)),
                dueAt: row.7.map { now.addingTimeInterval(Double($0 * 3600)) },
                reason: row.4, attention: row.5
            )
        }
    }
}
