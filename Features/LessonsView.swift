import SwiftUI

/// Every lesson Corres has learned from your corrections, with a way to
/// forget each one: learning you can see and undo, not a black box.
struct LessonsView: View {
    @State private var lessons = SenderLessons.all.sorted { $0.learnedAt > $1.learnedAt }
    @AppStorage(SenderLessons.enabledKey) private var isEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Learn from My Changes", isOn: $isEnabled)
            } footer: {
                Text("When you say an email Apple Intelligence flagged needs no action, Corres stops flagging that kind of email from that sender; their other mail is untouched. When you move a sender's automated email into Needs You, it keeps that kind there. Corres also notices habits, like lists you never open or people you always read at once, and suggests a change, at most once a day. Everything stays on this \(Device.name).")
            }
            Section {
                if lessons.isEmpty {
                    Text("Nothing yet. Corres learns as you correct it.").foregroundStyle(CorresPalette.secondary)
                } else {
                    ForEach(lessons) { lesson in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lesson.name).font(.body)
                            Text("\(lesson.summary) · \(lesson.learnedAt.formatted(.relative(presentation: .named)))")
                                .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onDelete { offsets in
                        for index in offsets { SenderLessons.forget(lessons[index].id) }
                        lessons.remove(atOffsets: offsets)
                    }
                }
            } header: {
                Text("Lessons")
            } footer: {
                if !lessons.isEmpty { Text("Swipe a lesson to forget it.") }
            }
            Section {
                    Button("Forget Everything", role: .destructive) {
                        SenderLessons.forgetAll()
                        HabitWatcher.shared.forgetAll()
                        UserDefaults.standard.removeObject(forKey: "corres.snoozeHabits")
                        lessons = []
                    }
            } footer: {
                Text("Also forgets the habits Corres has noticed: which lists you open, who you read first, and your usual snoozes.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("What Corres Has Learned")
        .inlineTitle()
    }
}
