import LinkPresentation
import SwiftUI
import UIKit

/// Writing an email in the Share sheet, laid out as Compose is: To with
/// your people suggested before you type, Cc, Bcc and From folded into one
/// line until you need them, the subject filled in from what you shared,
/// and the photos, files or page below what you write.
struct ShareComposeView: View {
    @Bindable var composer: ShareComposer
    var close: (_ completed: Bool) -> Void

    @State private var addressFocus: ShareComposer.Field? = .to
    @FocusState private var textFocus: ShareComposer.Field?
    @State private var showsMore = false
    @State private var confirmingCancel = false
    @State private var confirmingNoSubject = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if !composer.isSignedIn {
                    signedOut
                } else if composer.phase == .loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    form
                }
            }
            .background(CorresPalette.canvas)
            .navigationTitle(composer.subject.isEmpty ? "New Message" : composer.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if composer.hasChanges, composer.isSignedIn { confirmingCancel = true } else { close(false) }
                    }
                    .disabled(composer.phase == .sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if composer.subject.trimmingCharacters(in: .whitespaces).isEmpty { confirmingNoSubject = true } else { send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(CorresPalette.accentInk, composer.canSend ? CorresPalette.accent : Color.secondary.opacity(0.4))
                    }
                    .disabled(!composer.canSend)
                    .accessibilityLabel("Send")
                }
            }
            .confirmationDialog("", isPresented: $confirmingCancel, titleVisibility: .hidden) {
                Button("Delete Draft", role: .destructive) { close(false) }
                Button("Save Draft") {
                    Task { if await composer.saveDraft() { finish(after: 0.6) } }
                }
            }
            .alert("Send without a subject?", isPresented: $confirmingNoSubject) {
                Button("Add Subject", role: .cancel) { textFocus = .subject; addressFocus = nil }
                Button("Send") { send() }
            }
            .overlay { status }
        }
        .tint(CorresPalette.accent)
        .task(id: composer.phase) {
            if composer.phase == .sent || composer.phase == .queued { finish(after: composer.phase == .queued ? 2.2 : 0.7) }
        }
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                addressRow(.to)
                if addressFocus == .to || composer.to.isEmpty { suggestions(for: .to) }
                Hairline()
                if showsMore {
                    addressRow(.cc)
                    suggestions(for: .cc)
                    Hairline()
                    addressRow(.bcc)
                    suggestions(for: .bcc)
                    Hairline()
                    fromRow
                    Hairline()
                } else {
                    Button {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)) { showsMore = true }
                        addressFocus = .cc
                    } label: {
                        HStack {
                            Text(composer.accounts.count > 1 || composer.fromChoices.count > 1
                                 ? "Cc/Bcc, From: \(composer.fromLabel)" : "Cc/Bcc")
                                .font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Hairline()
                }
                HStack(spacing: 8) {
                    Text("Subject:").font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    TextField("", text: $composer.subject)
                        .focused($textFocus, equals: .subject)
                        .submitLabel(.next)
                        .onSubmit { textFocus = .body }
                }
                .padding(.horizontal, 16).frame(minHeight: 44)
                .onChange(of: textFocus) { _, field in if field != nil { addressFocus = nil } }
                Hairline()
                bodyEditor
                attachments
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var bodyEditor: some View {
        ZStack(alignment: .topLeading) {
            if composer.note.isEmpty {
                Text(composer.content.link != nil || !composer.content.files.isEmpty ? "Add a message" : "Message")
                    .foregroundStyle(CorresPalette.tertiary)
                    .padding(.horizontal, 16).padding(.top, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $composer.note)
                .focused($textFocus, equals: .body)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .padding(.horizontal, 11).padding(.top, 6)
                .frame(minHeight: composer.content.files.isEmpty && composer.content.link == nil ? 220 : 96)
        }
    }

    // MARK: Addresses

    private func addressRow(_ field: ShareComposer.Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(field.title):").font(.subheadline).foregroundStyle(CorresPalette.secondary)
            FlowLayout {
                ForEach(Array(composer.list(field).enumerated()), id: \.offset) { index, entry in
                    chip(entry, index: index, field: field)
                }
                AddressTextField(
                    text: Binding(get: { composer.typing[field] ?? "" }, set: { composer.typed($0, in: field) }),
                    placeholder: "",
                    isFocused: addressFocus == field,
                    onFocus: { focused in
                        if focused { addressFocus = field; textFocus = nil }
                        else if addressFocus == field { composer.commit(field); addressFocus = nil }
                    },
                    onEmptyBackspace: {
                        let count = composer.list(field).count
                        if count > 0 { composer.remove(at: count - 1, from: field) }
                    },
                    onSubmit: {
                        composer.commit(field)
                        if field == .to { textFocus = .subject; addressFocus = nil }
                    })
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(minHeight: 44)
    }

    private func chip(_ entry: String, index: Int, field: ShareComposer.Field) -> some View {
        let parsed = PeopleIndex.parse(entry)
        let label = parsed.map { $0.name.isEmpty ? $0.email : $0.name } ?? entry
        let tint = parsed == nil ? CorresPalette.alert : CorresPalette.accent
        return Menu {
            if let parsed { Section(parsed.email) {} }
            ForEach([ShareComposer.Field.to, .cc, .bcc].filter { $0 != field }, id: \.self) { target in
                Button { composer.move(at: index, from: field, to: target); showsMore = true } label: {
                    Label("Move to \(target.title)", systemImage: target == .bcc ? "eye.slash" : "arrow.right")
                }
            }
            Button(role: .destructive) { composer.remove(at: index, from: field) } label: { Label("Remove", systemImage: "minus.circle") }
        } label: {
            Text(label)
                .font(.subheadline).foregroundStyle(tint).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(tint.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel(parsed == nil ? "\(entry), not a valid address" : "\(label), \(parsed?.email ?? "")")
    }

    /// People you write to, before you type (as nobody else's share sheet
    /// offers), and matches as you do.
    @ViewBuilder
    private func suggestions(for field: ShareComposer.Field) -> some View {
        let typed = composer.typing[field] ?? ""
        if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = composer.matches(for: typed)
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches) { person in
                        Button { composer.add(person, to: field) } label: {
                            HStack(spacing: 12) {
                                monogram(person.displayName, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.displayName).font(.body).foregroundStyle(CorresPalette.ink).lineLimit(1)
                                    Text(person.email).font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if field == .to, addressFocus == .to || composer.to.isEmpty {
            let people = composer.suggestedPeople
            if !people.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(people) { person in
                            Button { composer.add(person, to: .to) } label: {
                                VStack(spacing: 6) {
                                    monogram(person.displayName, size: 44)
                                    Text(person.displayName.split(separator: " ").first.map(String.init) ?? person.email)
                                        .font(.caption).foregroundStyle(CorresPalette.ink).lineLimit(1)
                                        .frame(maxWidth: 64)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(person.displayName)")
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .transition(.opacity)
            }
        }
    }

    private func monogram(_ name: String, size: CGFloat) -> some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return Circle().fill(CorresPalette.avatarFill)
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.38, weight: .medium)).foregroundStyle(CorresPalette.ink))
            .accessibilityHidden(true)
    }

    private var fromRow: some View {
        Menu {
            ForEach(composer.fromChoices, id: \.address.email) { choice in
                Button {
                    composer.account = choice.account
                    composer.fromAddress = choice.address.email
                } label: {
                    if composer.fromAddress == choice.address.email { Label(choice.address.email, systemImage: "checkmark") }
                    else { Text(choice.address.email) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text("From:").font(.subheadline).foregroundStyle(CorresPalette.secondary)
                Text(composer.fromLabel).foregroundStyle(CorresPalette.ink).lineLimit(1)
                Spacer()
                if composer.fromChoices.count > 1 {
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(CorresPalette.tertiary)
                }
            }
            .padding(.horizontal, 16).frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(composer.fromChoices.count < 2)
    }

    // MARK: Attachments

    @ViewBuilder
    private var attachments: some View {
        if let link = composer.content.link {
            LinkCard(link: link)
                .padding(.horizontal, 16).padding(.top, 8)
        }
        if !composer.content.files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(composer.content.files) { file in fileCard(file) }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if !composer.photos.isEmpty {
                        Text("Photo Size").font(.subheadline).foregroundStyle(CorresPalette.ink)
                    }
                    Text(composer.isTooLarge
                         ? (composer.photos.isEmpty
                            ? "\(bytes(composer.totalBytes)) is over \(MailAccounts.serviceTitle(for: composer.account ?? ""))\u{2019}s \(composer.provider.attachmentLimitText) limit. Remove something."
                            : "\(bytes(composer.totalBytes)) is over \(MailAccounts.serviceTitle(for: composer.account ?? ""))\u{2019}s \(composer.provider.attachmentLimitText) limit. Remove something or pick a smaller size.")
                         : "\(composer.content.files.count == 1 ? "1 attachment" : "\(composer.content.files.count) attachments"), \(bytes(composer.totalBytes))")
                        .font(.footnote)
                        .foregroundStyle(composer.isTooLarge ? CorresPalette.alert : CorresPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !composer.photos.isEmpty {
                    Menu {
                        Picker("Photo Size", selection: $composer.photoSize) {
                            ForEach(PhotoSize.allCases) { size in
                                Text(composer.totals[size].map { "\(size.title), \(bytes($0))" } ?? size.title).tag(size)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(composer.photoSize.title).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline)
                        .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 2)
        }
    }

    private func fileCard(_ file: SharedContent.File) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = file.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                        .frame(width: 88, height: 88).clipped()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: file.mimeType.hasPrefix("video/") ? "film" : file.mimeType == "application/pdf" ? "doc.richtext" : "doc")
                            .font(.title2).foregroundStyle(CorresPalette.accent)
                        Text(file.filename).font(.caption2).foregroundStyle(CorresPalette.ink)
                            .lineLimit(2).multilineTextAlignment(.center)
                        Text(bytes(file.data.count)).font(.caption2).foregroundStyle(CorresPalette.tertiary)
                    }
                    .padding(8)
                    .frame(width: 110, height: 88)
                    .background(CorresPalette.surfaceRaised)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CorresPalette.line, lineWidth: 0.5))
            Button { withAnimation(.snappy) { composer.removeFile(file.id) } } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .font(.title3)
            }
            .padding(4)
            .accessibilityLabel("Remove \(file.filename)")
        }
    }

    private func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    // MARK: Sending

    private func send() {
        addressFocus = nil
        textFocus = nil
        Task { await composer.send() }
    }

    private func finish(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            close(true)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch composer.phase {
        case .sending:
            badge("Sending\u{2026}") { ProgressView().controlSize(.large) }
        case .sent:
            badge("Sent") {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(CorresPalette.accent)
            }
        case .queued:
            badge("No connection. Corres will send it as soon as it can.") {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 36)).foregroundStyle(CorresPalette.accent)
            }
        case .failed(let message):
            Color.clear.alert("Couldn\u{2019}t Send", isPresented: .constant(true)) {
                Button("OK") { composer.retry() }
            } message: { Text(message) }
        default:
            EmptyView()
        }
    }

    private func badge<Icon: View>(_ text: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 12) {
            icon()
            Text(text).font(.headline).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .sensoryFeedback(.success, trigger: composer.phase) { _, new in new == .sent }
    }

    private var signedOut: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge.person.crop").font(.system(size: 44)).foregroundStyle(CorresPalette.accent)
            Text("Open Corres First").font(.title3.weight(.semibold))
            Text("Open Corres once (and add your email account if you haven\u{2019}t), then share again to write right here.")
                .font(.subheadline).foregroundStyle(CorresPalette.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The shared page as a card, the way Messages and Mail show a link.
private struct LinkCard: View {
    let link: SharedContent.Link

    var body: some View {
        Group {
            if let metadata = link.metadata {
                LinkPreview(metadata: metadata).frame(maxWidth: .infinity, minHeight: 64)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "safari").font(.title2).foregroundStyle(CorresPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.title ?? link.url.host() ?? "Link").font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(link.url.host() ?? link.url.absoluteString).font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(12)
                .background(CorresPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LinkPreview: UIViewRepresentable {
    let metadata: LPLinkMetadata
    func makeUIView(context: Context) -> LPLinkView {
        let view = LPLinkView(metadata: metadata)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: LPLinkView, context: Context) { view.metadata = metadata }
}
