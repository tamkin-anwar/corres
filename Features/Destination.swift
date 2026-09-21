import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case brief = "Brief", needsYou = "Needs You", waiting = "Waiting", mail = "Mail"
    var id: String { rawValue }
    var glyph: CorresGlyph {
        switch self { case .brief: .brief; case .needsYou: .needsYou; case .waiting: .waiting; case .mail: .mail }
    }
    var attention: Attention? {
        switch self { case .needsYou: .needsYou; case .waiting: .waiting; default: nil }
    }
}

