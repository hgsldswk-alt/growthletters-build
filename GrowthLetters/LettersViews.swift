import SwiftUI
import UIKit

struct WriteView: View {
    @Bindable var model: AppModel
    @FocusState private var focus: Bool
    @State private var focusChild: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    ScreenTitle(title: L.t("write.title"), subtitle: L.t("app.title"))
                    TextAction(title: L.t("settings.title"), id: "write.settings") {
                        focus = false
                        model.show(.settings)
                    }
                }
                ChildChoices(model: model, inComposer: true) { id in
                    model.select(id)
                    if model.active.id == id && model.canWrite { focusChild = id }
                }
                childActions
                if model.canWrite { paper }
                else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L.t("write.secondaryLocked"))
                        Action(title: L.t("paywall.title"), id: "write.unlock") { _ = model.requirePro() }
                    }.modifier(LetterPaper(tint: Theme.tint))
                }
                StatusLine(model: model)
                if model.saveFeedback.contains(.tenth) { milestone(.tenth) }
                if model.saveFeedback.contains(.firstBirthday) { milestone(.firstBirthday) }
                if !focus {
                    let letters = model.letters
                    if let latest = letters.first { recent(latest, count: letters.count) }
                    TextAction(title: L.t("incoming.write"), id: "write.family") { model.show(.compose) }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onChange(of: model.active.id) { _, _ in
            if !model.canWrite { focus = false }
        }
        .onChange(of: focus) { _, value in model.editorFocused = value }
        .onDisappear { model.editorFocused = false }
        .task(id: focusChild) {
            guard let focusChild, model.active.id == focusChild, model.canWrite else { return }
            focus = true
            self.focusChild = nil
        }
        .sheet(isPresented: $model.datePickerOpen) { dateSheet }
    }

    private var childActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { editChild; reminder }
            VStack(alignment: .leading, spacing: 0) { editChild; reminder }
        }
    }

    private var editChild: some View {
        TextAction(title: L.t(model.active.birthday == nil ? "child.addBirthday" : "child.edit"), id: "write.child") {
            focus = false
            model.show(.child(false))
        }
    }

    private var reminder: some View {
        TextAction(title: L.t("reminder.title"), id: "write.reminder") {
            focus = false
            model.show(.reminder)
        }
    }

    private func recent(_ letter: Letter, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L.t("write.recent")).font(.caption.weight(.semibold))
            Text(letter.summary).font(.system(.body, design: .serif)).lineLimit(2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { recentActions(letter, count: count) }
                VStack(alignment: .leading, spacing: 0) { recentActions(letter, count: count) }
            }
        }
        .modifier(LetterPaper())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("write.recent")
        .contextMenu {
            Button(L.t("letter.edit")) { model.show(.edit(letter.id)) }
                .accessibilityIdentifier("write.recent.editMenu")
        }
    }

    @ViewBuilder
    private func recentActions(_ letter: Letter, count: Int) -> some View {
        TextAction(title: L.t("action.share"), id: "write.recent.share") {
            Task { await model.shareCard(count: count) }
        }.disabled(model.exporting)
        TextAction(title: L.t("letter.edit"), id: "write.recent.edit") { model.show(.edit(letter.id)) }
        TextAction(title: L.t("book.title"), id: "write.recent.book") { model.show(.book) }
    }

    private var dateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            CivilDatePicker(title: L.t("write.changeDate"), day: Binding(get: { model.draft.day },
                set: { value in
                    model.updateDraft {
                        $0.day = value
                        $0.hasChosenDay = true
                    }
                }), id: "write.date.calendar").datePickerStyle(.graphical)
            Action(title: L.t("action.done"), id: "write.date.done", primary: true) { model.datePickerOpen = false }
            Spacer(minLength: 0)
        }.padding(20).presentationDetents([.large])
    }

    var paper: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.draft.day.display)
                    .font(.caption.weight(.bold)).tracking(0.6).foregroundStyle(Theme.accentInk)
                Spacer()
                if let birth = model.active.birthday {
                    Text(birth.age(on: model.draft.day).display).font(.caption).foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("letter.age")
                }
            }
            TextAction(title: L.t("write.changeDate"), id: "write.date") {
                focus = false
                model.datePickerOpen = true
            }
            Divider()
            PaperEditor(text: Binding(get: { model.draft.body }, set: { text in model.updateDraft { $0.body = text } }),
                        focus: $focus, placeholder: L.t("prompt.\(model.today.day % 4)"))
            if !focus, let id = model.draft.photo { StoredPhoto(id: id, model: model).id(id) }
            if Launch.uiTesting && Launch.args.contains("-photo-failure") {
                TextAction(title: L.t("photo.add"), id: "write.photo") { model.error = GrowthError.photo.message }
            } else {
                let child = model.active.id
                PhotoControl(hasPhoto: model.draft.photo != nil, id: "write.photo",
                             busy: Binding(get: { model.photoBusy }, set: { model.photoBusy = $0 }),
                             presented: $model.photoPickerOpen,
                             onPhoto: { model.attachDraftPhoto($0, to: child) },
                             onRemove: model.removeDraftPhoto,
                             failed: { model.error = GrowthError.photo.message })
            }
        }.modifier(LetterPaper())
    }

    var footer: some View {
        VStack(spacing: 0) {
            if model.canWrite {
                Action(title: L.t("write.save"), id: "write.save", primary: true) {
                    focus = false
                    Task { await model.saveLetter() }
                }
                .disabled(model.writing || model.photoBusy || model.draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(model.draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.65 : 1)
                .padding(.horizontal, 20).padding(.vertical, 7)
                if !focus {
                    Text(L.t("write.local")).font(.caption).foregroundStyle(Theme.muted).padding(.bottom, 9)
                }
            }
            MainTabs(model: model)
        }.background(Theme.paper)
    }

    func milestone(_ value: Milestone) -> some View {
        MilestoneLine(model: model, milestone: value, count: model.letters.count)
    }
}

struct MilestoneLine: View {
    let model: AppModel
    let milestone: Milestone
    let count: Int

    var body: some View {
        HStack {
            Text(L.t(milestone == .tenth ? "milestone.tenth" : "milestone.birthday"))
                .font(.subheadline.weight(.semibold))
            Spacer()
            TextAction(title: L.t("card.make"), id: "milestone.\(milestone.rawValue)") {
                model.show(.card(milestone == .tenth ? 10 : count, milestone))
            }
        }.modifier(LetterPaper(tint: Theme.tint))
    }
}

struct FolderView: View {
    let model: AppModel
    @State private var search = ""
    @State private var searchMatches: Set<UUID>?
    @State private var searchBusy = false

    private struct Query: Hashable {
        let value: String
        let child: UUID
        let revisions: [Letter]
    }

    private var groups: [(Int, [Letter])] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = model.letters.filter { needle.isEmpty || searchMatches?.contains($0.id) == true }
        return Dictionary(grouping: found, by: { $0.day.year })
            .sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    ScreenTitle(title: L.t("tab.letters"), subtitle: L.f("folder.title", model.active.name))
                    TextAction(title: L.t("child.edit"), id: "child.edit") { model.show(.child(false)) }
                }
                HStack {
                    ChildChoices(model: model)
                    TextAction(title: L.t("child.add"), id: "child.add") {
                        if model.requirePro() { model.show(.child(true)) }
                    }
                }
                HStack {
                    Text(L.f("letters.count", model.letters.count)).font(.headline)
                    Spacer()
                    if let birthday = model.active.birthday {
                        Text(birthday.age(on: model.today).display).font(.caption).foregroundStyle(Theme.muted)
                            .accessibilityIdentifier("folder.age")
                    }
                }.modifier(LetterPaper())
                HStack {
                    Action(title: L.t("book.title"), id: "folder.book") { model.show(.book) }
                    Action(title: L.t("reminder.title"), id: "folder.reminder") { model.show(.reminder) }
                }
                if let reminder = model.state.reminders[model.active.id] { reminderLine(reminder) }
                if model.state.milestonePrompts {
                    ForEach(Milestone.allCases.filter { model.state.milestones[model.active.id, default: []].contains($0) }) {
                        MilestoneLine(model: model, milestone: $0, count: model.letters.count)
                    }
                }
                if model.state.undoLetter?.childID == model.active.id {
                    TextAction(title: L.t("status.undo"), id: "letter.undo") { Task { await model.undoDelete() } }
                }
                StatusLine(model: model)
                if model.letters.count >= 5 {
                    TextField(L.t("folder.search"), text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("folder.search")
                }
                if searchBusy {
                    ProgressView()
                } else if groups.isEmpty {
                    Text(L.t(search.isEmpty ? "empty.letters" : "folder.noResults")).foregroundStyle(Theme.muted)
                }
                ForEach(groups, id: \.0) { year, letters in
                    Text(String(year)).font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.accentInk)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(letters) { letterRow($0) }
                }
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.active.id) { _, _ in search = "" }
        .safeAreaInset(edge: .bottom, spacing: 0) { MainTabs(model: model) }
        .task(id: Query(value: search, child: model.active.id, revisions: model.letters)) { await findLetters() }
    }

    private func findLetters() async {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        searchMatches = nil
        searchBusy = !needle.isEmpty
        guard !needle.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let matches = try await model.search(needle, in: model.letters)
            guard !Task.isCancelled else { return }
            searchMatches = matches
        } catch {
            guard !Task.isCancelled else { return }
            model.error = GrowthError.storage.message
        }
        searchBusy = false
    }

    func reminderLine(_ reminder: OpeningReminder) -> some View {
        HStack {
            Image(systemName: "calendar").accessibilityHidden(true)
            Text(L.f(reminder.day <= model.today ? "reminder.due" : "reminder.scheduled", reminder.day.display))
                .font(.caption)
            Spacer()
        }.modifier(LetterPaper())
    }

    func letterRow(_ letter: Letter) -> some View {
        Button {
            model.show(.read(letter.id))
        } label: {
            HStack(spacing: 12) {
                Circle().fill(Theme.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    let age = model.active.historyAge(on: letter.day).map { " · " + $0 } ?? ""
                    Text(letter.day.display + age).font(.caption).foregroundStyle(Theme.muted)
                    Text(letter.summary).font(.system(.body, design: .serif).weight(.semibold))
                        .lineLimit(2).foregroundStyle(Theme.ink)
                    if let sender = letter.sender, !sender.isEmpty {
                        Text(L.f("letter.from", sender)).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 0)
                if let photo = letter.photo { StoredPhoto(id: photo, model: model, thumbnail: true) }
            }
            .padding(.vertical, 5).frame(minHeight: 51).contentShape(Rectangle())
            .background(alignment: .leading) {
                Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 2.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("letter.row")
    }
}

struct ReadView: View {
    let model: AppModel
    let id: UUID
    @State private var text: String?

    var body: some View {
        if let letter = model.state.letters.first(where: { $0.id == id }),
           let child = model.state.children.first(where: { $0.id == letter.childID }) {
            let age = child.historyAge(on: letter.day).map { " · " + $0 } ?? ""
            DetailPage(model: model, title: letter.summary, subtitle: letter.day.display + age) {
                HStack {
                    Text(L.f("child.for", child.name)).font(.subheadline).foregroundStyle(Theme.accentInk)
                    Spacer()
                    TextAction(title: L.t("letter.edit"), id: "read.edit") { model.show(.edit(id)) }
                }
                VStack(alignment: .leading, spacing: 14) {
                    if let sender = letter.sender, !sender.isEmpty {
                        Text(L.f("letter.from", sender)).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    if let text {
                        Text(text)
                            .font(.system(.body, design: .serif)).lineSpacing(5).textSelection(.enabled)
                            .accessibilityIdentifier("read.body")
                    } else { ProgressView() }
                    if let photo = letter.photo { StoredPhoto(id: photo, model: model).id(photo) }
                }.modifier(LetterPaper())
                let childLetters = model.state.letters(for: child.id).reversed()
                let ordinal = Array(childLetters).firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? childLetters.count
                Action(title: L.t("card.make"), id: "read.card") { model.show(.card(ordinal, nil)) }
                TextAction(title: L.t("letter.delete"), id: "read.delete") { Task { await model.delete(letter) } }
            }.task(id: letter) {
                do {
                    let full = try await model.fullLetter(letter)
                    if !Task.isCancelled { text = full.body }
                } catch { if !Task.isCancelled { model.error = GrowthError.storage.message } }
            }
        }
    }
}

struct EditLetterLoader: View {
    let model: AppModel
    let id: UUID
    @State private var letter: Letter?

    var body: some View {
        Group {
            if let letter { EditLetterView(model: model, letter: letter) }
            else { DetailPage(model: model, title: L.t("letter.edit")) { ProgressView() } }
        }.task(id: id) {
            guard let header = model.state.letters.first(where: { $0.id == id }) else { return }
            do { letter = try await model.fullLetter(header) }
            catch { if !Task.isCancelled { model.error = GrowthError.storage.message } }
        }
    }
}

struct EditLetterView: View {
    let model: AppModel
    @State var letter: Letter
    @State private var photo: Data?
    @State private var busy = false
    @FocusState private var focus: Bool

    init(model: AppModel, letter: Letter) {
        self.model = model
        self._letter = State(initialValue: letter)
    }

    var body: some View {
        DetailPage(model: model, title: L.t("letter.edit")) {
            VStack(alignment: .leading, spacing: 10) {
                CivilDatePicker(title: L.t("write.changeDate"), day: $letter.day, id: "edit.date")
                PaperEditor(text: $letter.body, focus: $focus, id: "edit.body")
                if let photo, let image = UIImage(data: photo) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200)
                        .accessibilityLabel(L.t("photo.attachment"))
                } else if let id = letter.photo { StoredPhoto(id: id, model: model).id(id) }
                PhotoControl(hasPhoto: letter.photo != nil, id: "edit.photo", busy: $busy, onPhoto: {
                    letter.photo = UUID()
                    photo = $0
                }, onRemove: {
                    letter.photo = nil
                    photo = nil
                }, failed: { model.error = GrowthError.photo.message })
            }.modifier(LetterPaper())
            Action(title: L.t("write.save"), id: "edit.save", primary: true) {
                focus = false
                Task { await model.edit(letter, photo: photo) }
            }.disabled(model.writing || busy || !Letter.validBody(letter.body))
        }
    }
}

struct ChildEditor: View {
    let model: AppModel
    let new: Bool
    @State private var name = ""
    @State private var birthday = CivilDay(2024, 8, 23)
    @State private var hasBirthday = false
    @State private var gender: Child.Gender?

    var body: some View {
        DetailPage(model: model, title: L.t(new ? "child.add" : "child.edit")) {
            VStack(alignment: .leading, spacing: 12) {
                TextField(L.t("child.nickname"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("child.nickname")
                if hasBirthday {
                    CivilDatePicker(title: L.t("child.birthday"), day: $birthday, id: "child.birthday",
                                    range: CivilDay(1900, 1, 1).date()...model.today.date())
                    TextAction(title: L.t("child.clearBirthday"), id: "child.clearBirthday") { hasBirthday = false }
                } else {
                    BirthdayPicker(title: L.t("child.birthday"), day: $birthday, enabled: $hasBirthday, today: model.today)
                }
                Picker(L.t("child.gender"), selection: $gender) {
                    Text(L.t("child.gender.unknown")).tag(nil as Child.Gender?)
                    ForEach(Child.Gender.allCases, id: \.rawValue) {
                        Text(L.t("child.gender.\($0.rawValue)")).tag(Optional($0))
                    }
                }.frame(minHeight: 44).accessibilityIdentifier("child.gender")
            }.modifier(LetterPaper())
            Action(title: L.t("child.save"), id: "child.save", primary: true) {
                Task { await model.saveChild(name: name, birthday: hasBirthday ? birthday : nil, gender: gender, new: new) }
            }.disabled(model.writing)
        }.onAppear {
            if !new {
                name = model.active.nickname
                hasBirthday = model.active.birthday != nil
                gender = model.active.gender
            }
            birthday = (!new ? model.active.birthday : nil) ?? CivilDay(model.today.year - 2, model.today.month, model.today.day)
            if !birthday.valid { birthday = model.today }
        }
    }
}

struct BirthdayPicker: View {
    let title: String
    @Binding var day: CivilDay
    @Binding var enabled: Bool
    let today: CivilDay

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            DatePicker(title, selection: Binding(get: { day.date() }, set: {
                day = CivilDay($0)
                enabled = true
            }), in: CivilDay(1900, 1, 1).date()...today.date(), displayedComponents: .date)
            .datePickerStyle(.compact)
            .environment(\.calendar, CivilDay.calendar())
            .labelsHidden()
            .accessibilityIdentifier("child.birthday")
        }
        .frame(minHeight: 44)
    }
}
