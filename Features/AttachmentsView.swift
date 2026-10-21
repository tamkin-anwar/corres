import SwiftUI

/// Mailboxes → Attachments: every file in your mail, on every account,
/// newest first, by kind. Found by name, sender or subject; opening one
/// takes you to its conversation, where it downloads and opens.
struct AttachmentsView: View {
    let store: MailStore
    let accounts: [String]
    let open: (ThreadID) -> Void
    @State private var kind: Kind = .all
    @State private var search = ""

    enum Kind: String, CaseIterable, Identifiable {
        case all, photos, documents, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .photos: String(localized: "Photos and Videos")
            case .documents: String(localized: "Documents")
            case .other: String(localized: "Other")
            }
        }

        func includes(_ kind: AttachmentKind) -> Bool {
            switch self {
            case .all: true
            case .photos: kind == .image || kind == .video
            case .documents: [.pdf, .word, .excel, .powerpoint, .pages, .numbers, .keynote, .text].contains(kind)
            case .other: [.audio, .archive, .calendar, .contact, .other].contains(kind)
            }
        }
    }

    struct Item: Identifiable {
        let thread: Correspondence
        let file: MailAttachment
        let kind: AttachmentKind
        var id: String { thread.id.account + thread.id.providerID + file.id }
    }

    private var items: [Item] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let threads = store.searchableThreads
            .filter { (accounts.isEmpty || accounts.contains($0.id.account)) && !$0.attachments.isEmpty }
            .sorted { $0.receivedAt > $1.receivedAt }
        var result: [Item] = []
        for thread in threads {
            for file in thread.attachments {
                let fileKind = AttachmentKind(filename: file.filename, mimeType: file.mimeType)
                // Calendar invitations and signatures' little logos aren't
                // what anyone is looking for here.
                if fileKind == .calendar || (fileKind == .image && file.sizeBytes < 12_000) { continue }
                guard kind.includes(fileKind) else { continue }
                if !query.isEmpty {
                    let fields = [file.filename, thread.sender, thread.subject]
                    guard fields.contains(where: { $0.localizedStandardContains(query) }) else { continue }
                }
                result.append(Item(thread: thread, file: file, kind: fileKind))
            }
        }
        return result
    }

    var body: some View {
        let items = items
        List {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            ForEach(items) { item in
                Button { open(item.thread.id) } label: { AttachmentFileRow(item: item) }
                    .buttonStyle(.plain)
                    .listRowBackground(CorresPalette.surface)
            }
        }
        .searchable(text: $search, prompt: Text("Name, sender or subject"))
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Attachments")
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(search.isEmpty ? String(localized: "No Attachments") : String(localized: "No Matches"),
                                       systemImage: "paperclip",
                                       description: Text(search.isEmpty ? "Files sent to you or by you show here." : "Try another name."))
            }
        }
    }
}

private struct AttachmentFileRow: View {
    let item: AttachmentsView.Item

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.systemImage)
                .font(.title3)
                .foregroundStyle(CorresPalette.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.file.filename).foregroundStyle(CorresPalette.ink).lineLimit(1)
                Text("\(item.thread.sender) · \(item.thread.receivedAt.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.file.sizeBytes), countStyle: .file))
                .font(.caption).foregroundStyle(CorresPalette.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens its conversation")
    }
}

extension AttachmentKind {
    var systemImage: String {
        switch self {
        case .pdf: "doc.richtext"
        case .word, .pages, .text: "doc.text"
        case .excel, .numbers: "tablecells"
        case .powerpoint, .keynote: "rectangle.on.rectangle"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "doc.zipper"
        case .calendar: "calendar"
        case .contact: "person.crop.square"
        case .other: "doc"
        }
    }

    static func symbol(for file: MailAttachment) -> String {
        AttachmentKind(filename: file.filename, mimeType: file.mimeType).systemImage
    }
}
