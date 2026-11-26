import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImportView: View {
    let model: AppModel
    @State private var pickFile = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(title: L.t("tab.receive"), subtitle: L.t("incoming.subtitle"))
                VStack(alignment: .leading, spacing: 11) {
                    Text(L.f("incoming.for", model.active.name)).font(.headline)
                    Text(L.t("incoming.help")).foregroundStyle(Theme.muted)
                    Action(title: L.t("incoming.paste"), id: "import.paste", primary: true) {
                        let code: String?
                        if Launch.uiTesting {
                            code = ProcessInfo.processInfo.environment["GL_PASTE_CODE"] ??
                                (try? IncomingLetter(day: CivilDay(2026, 11, 21), body: L.t("sample.family"),
                                                    sender: L.t("sample.grandma")).code())
                        } else {
                            code = UIPasteboard.general.string
                        }
                        if let code { Task { await model.receiveCode(code) } }
                        else { model.error = L.t("error.clipboard") }
                    }
                    Action(title: L.t("incoming.file"), id: "import.file") {
                        if Launch.uiTesting && Launch.args.contains("-fixture-file") { Task { await model.openFixtureLetter() } }
                        else { pickFile = true }
                    }
                }.modifier(LetterPaper())
                VStack(alignment: .leading, spacing: 10) {
                    Action(title: L.t("incoming.write"), id: "import.compose") { model.show(.compose) }
                    Action(title: L.t("incoming.invite"), id: "import.invite") {
                        let link = (Launch.storeURL ?? Launch.previewURL).absoluteString
                        model.share(ShareRequest(text: model.active.invitation + "\n" + link))
                    }
                }.modifier(LetterPaper())
                StatusLine(model: model)
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MainTabs(model: model) }
        .fileImporter(isPresented: $pickFile, allowedContentTypes: [.growthLetter]) { result in
            switch result {
            case .success(let url): Task { await model.openFile(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.error = GrowthError.invalid.message }
            }
        }
    }
}

struct FamilyComposeView: View {
    let model: AppModel
    @State private var bodyText = ""
    @State private var sender = ""
    @State private var day = CivilDay.today
    @State private var photo: Data?
    @State private var busy = false
    @State private var photoPickerOpen = false
    @State private var senderFocusPending = false
    @State private var payloadID = UUID()
    @FocusState private var focus: Bool
    @FocusState private var senderFocused: Bool

    var body: some View {
        DetailPage(model: model, title: L.t("incoming.write")) {
            VStack(alignment: .leading, spacing: 10) {
                PaperEditor(text: $bodyText, focus: $focus, id: "family.body", minHeight: 104)
                TextField(L.t("incoming.sender"), text: $sender)
                    .textFieldStyle(.roundedBorder).frame(minHeight: 44)
                    .focused($senderFocused)
                    .accessibilityIdentifier("family.sender")
                if Launch.uiTesting && Launch.args.contains("-family-photo") {
                    TextAction(title: L.t("photo.add"), id: "family.photo") {
                        Task { await addFixturePhoto() }
                    }
                } else {
                    PhotoControl(hasPhoto: photo != nil, id: "family.photo", busy: $busy, presented: $photoPickerOpen,
                                 onPhoto: addPhoto, onRemove: { photo = nil }, failed: { model.error = GrowthError.photo.message })
                }
                if let photo, let image = UIImage(data: photo) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 85)
                        .accessibilityLabel(L.t("photo.attachment"))
                        .accessibilityIdentifier("family.attachment")
                }
            }.modifier(LetterPaper())
            CivilDatePicker(title: L.t("write.changeDate"), day: $day, id: "family.date")
            Text(L.t("incoming.private")).font(.caption).foregroundStyle(Theme.muted)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Action(title: L.t("incoming.share"), id: "family.share", primary: true) {
                focus = false
                senderFocused = false
                send()
            }.disabled(busy || model.exporting || !Letter.validBody(bodyText))
                .padding(.horizontal, 20).padding(.vertical, 7).background(Theme.paper)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(225))
            if !Task.isCancelled { focus = true }
        }
        .task(id: senderFocusPending && !photoPickerOpen) {
            guard senderFocusPending && !photoPickerOpen else { return }
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            senderFocusPending = false
            if sender.isEmpty { focusSender() }
        }
        .onChange(of: bodyText) { _, _ in payloadID = UUID() }
        .onChange(of: sender) { _, _ in payloadID = UUID() }
        .onChange(of: day) { _, _ in payloadID = UUID() }
        .onChange(of: photo) { _, _ in payloadID = UUID() }
    }

    private func addPhoto(_ data: Data) {
        photo = data
        if sender.isEmpty { senderFocusPending = true }
    }

    private func focusSender() {
        focus = false
        senderFocused = true
    }

    private func addFixturePhoto() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await Task.detached {
                guard let url = AppModel.samplePhotoURL() else { throw GrowthError.photo }
                return try PhotoCodec.clean(Data(contentsOf: url))
            }.value
            photo = data
            focusSender()
        } catch { model.error = GrowthError.photo.message }
    }

    func send() {
        let payload = IncomingLetter(id: payloadID, day: day, body: bodyText,
                                     sender: String(sender.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48)), photo: photo)
        Task {
            await model.export {
                let checked = try payload.validated()
                if let code = try checked.code() { return ShareRequest(text: code) }
                let bytes = try JSONEncoder().encode(checked)
                let file = try TransferFiles.write(bytes, named: "FamilyLetter.growthletter")
                return ShareRequest(files: [file])
            }
        }
    }
}

struct IncomingView: View {
    let model: AppModel
    @State private var expanded = false

    var body: some View {
        if let letter = model.incoming {
            let target = model.state.children.first { $0.id == model.incomingTarget } ?? model.active
            DetailPage(model: model, title: L.t("incoming.preview"), subtitle: L.f("incoming.for", target.name)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(letter.day.display).font(.caption.weight(.semibold)).foregroundStyle(Theme.accentInk)
                    Text(letter.sender.isEmpty ? L.t("incoming.unsigned") : L.f("letter.from", letter.sender)).font(.subheadline)
                    Text(expanded ? letter.body : letter.previewText).font(.system(.body, design: .serif)).lineSpacing(4)
                        .lineLimit(expanded ? nil : 2)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(expanded ? "incoming.body.full" : "incoming.body")
                    TextAction(title: L.t(expanded ? "incoming.collapse" : "incoming.expand"), id: "incoming.expand") {
                        expanded.toggle()
                    }
                    if let data = letter.photo, let photo = UIImage(data: data) {
                        Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 250)
                            .accessibilityLabel(L.t("photo.attachment"))
                            .accessibilityIdentifier("incoming.attachment")
                    }
                }.modifier(LetterPaper())
                if model.state.children.count > 1 {
                    ChildChoices(model: model, selection: target.id) { model.incomingTarget = $0 }
                }
                Action(title: L.f("incoming.addTo", target.name), id: "incoming.add", primary: true) {
                    Task { await model.acceptIncoming() }
                }.disabled(model.writing)
            }
            .onChange(of: letter.id) { _, _ in expanded = false }
        }
    }
}

struct CardView: View {
    let model: AppModel
    let count: Int
    let milestone: Milestone?
    @State private var includeName = false
    @State private var art: UIImage?

    var body: some View {
        DetailPage(model: model, title: L.t("card.title")) {
            Group {
                if let art { Image(uiImage: art).resizable().scaledToFit().frame(maxHeight: 380) }
                else { ProgressView().frame(minHeight: 200) }
            }.frame(maxWidth: .infinity).modifier(LetterPaper(tint: Theme.desk))
                .accessibilityLabel(L.t("card.title"))
            if !model.active.nickname.isEmpty {
                Toggle(L.t("card.nickname"), isOn: $includeName)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("card.nickname")
            }
            Action(title: L.t("card.share"), id: "card.share", primary: true) {
                let name = includeName ? model.active.nickname : nil
                Task { await model.shareCard(count: count, nickname: name, milestone: milestone) }
            }.disabled(model.exporting || art == nil)
        }
        .task(id: includeName) {
            art = nil
            let name = includeName ? model.active.nickname : nil
            do {
                let image = try await Task.detached { try CardArt.make(count: count, nickname: name, milestone: milestone,
                                                                       storeURL: Launch.storeURL) }.value
                if !Task.isCancelled { art = image }
            } catch { if !Task.isCancelled { model.error = GrowthError.storage.message } }
        }
    }
}
