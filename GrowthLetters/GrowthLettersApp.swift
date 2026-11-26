import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@main
@MainActor
struct GrowthLettersApp: App {
    @State private var model = AppModel()
    private let reminderDelegate = ReminderDelegate()

    init() {
        if !Launch.uiTesting { UNUserNotificationCenter.current().delegate = reminderDelegate }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.light)
                .onOpenURL { model.handle($0) }
                .onReceive(NotificationCenter.default.publisher(for: ReminderDelegate.opened)) {
                    if let value = $0.object as? String, let id = UUID(uuidString: value) { model.openReminder(id) }
                }
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var keyboardVisible = false
    @State private var shareFailed = false

    private var reviewIdle: Bool {
        scenePhase == .active && model.tab == .write && model.path.isEmpty &&
        !keyboardVisible && !model.editorFocused && !model.datePickerOpen && !model.photoPickerOpen &&
        !model.photoBusy && !model.writing && !model.exporting && !model.purchasing &&
        model.shareRequest == nil && model.error == nil
    }

    private var reviewTicket: UUID? { reviewIdle ? model.reviewOpportunity.ticket : nil }

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                if !model.ready {
                    VStack(spacing: 20) {
                        if model.error == nil { ProgressView().accessibilityLabel(L.t("status.loading")) }
                        else { Action(title: L.t("action.retry"), id: "launch.retry") { Task { await model.boot() } } }
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch model.tab {
                    case .write: WriteView(model: model)
                    case .letters: FolderView(model: model)
                    case .receive: ImportView(model: model)
                    }
                }
            }
            .background(Theme.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AppModel.Route.self) { route in
                detail(route)
                    .background(Theme.paper.ignoresSafeArea())
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .tint(Theme.accentInk)
        .foregroundStyle(Theme.ink)
        .task { await model.boot() }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                model.updateClock()
                model.refreshEmptyDates()
                if model.ready {
                    Task {
                        await model.refreshAnniversaries()
                        await model.refreshAccess()
                    }
                }
            } else {
                model.reviewOpportunity.cancel()
                model.flushDrafts(inBackground: new == .background)
            }
        }
        .sheet(item: $model.shareRequest, onDismiss: {
            if shareFailed {
                shareFailed = false
                model.error = L.t("error.share")
            }
        }) { request in
            SystemShare(request: request) { failed in
                shareFailed = failed
                model.shareRequest = nil
            }
            .onDisappear { request.cleanup() }
        }
        .alert(L.t("error.title"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L.t("action.ok"), role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
        }
        .task(id: reviewTicket) {
            guard let ticket = reviewTicket else { return }
            do { try await Task.sleep(for: .seconds(1.4)) }
            catch { return }
            await model.requestReview(for: ticket, isIdle: { reviewIdle }) {
                if Launch.uiTesting { model.testReview = true }
                else { requestReview() }
            }
        }
    }

    @ViewBuilder
    func detail(_ route: AppModel.Route) -> some View {
        switch route {
        case .settings: SettingsView(model: model)
        case .child(let new): ChildEditor(model: model, new: new)
        case .read(let id): ReadView(model: model, id: id)
        case .edit(let id): EditLetterLoader(model: model, id: id)
        case .book: BookView(model: model)
        case .reminder: ReminderView(model: model)
        case .compose: FamilyComposeView(model: model)
        case .incoming: IncomingView(model: model)
        case .card(let count, let milestone): CardView(model: model, count: count, milestone: milestone)
        case .paywall: PaywallView(model: model)
        }
    }
}

struct SystemShare: UIViewControllerRepresentable {
    let request: ShareRequest
    let close: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = request.files
        if let text = request.text { items.append(text) }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            let failed = error != nil
            DispatchQueue.main.async { close(failed) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct MainTabs: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            tab(.write, key: "tab.write")
            tab(.letters, key: "tab.letters")
            tab(.receive, key: "tab.receive")
        }
        .background(Theme.paper)
        .overlay(alignment: .top) { Divider() }
    }

    func tab(_ tab: AppModel.Tab, key: String) -> some View {
        Button {
            model.switchTab(tab)
        } label: {
            Text(L.t(key)).font(.subheadline.weight(.semibold))
                .foregroundStyle(model.tab == tab ? Theme.accentInk : Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 49)
                .contentShape(Rectangle())
                .overlay(alignment: .top) {
                    if model.tab == tab { Rectangle().fill(Theme.accent).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(key)
        .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
    }
}

struct DetailPage<Content: View>: View {
    let model: AppModel
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextAction(title: L.t("action.back"), id: "nav.back") { model.back() }
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 680)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenTitle(title: title, subtitle: subtitle)
                    content()
                    StatusLine(model: model)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.paper)
    }
}

struct StatusLine: View {
    let model: AppModel

    var body: some View {
        if let status = model.status {
            Text(status).font(.subheadline).foregroundStyle(Theme.accentInk).accessibilityIdentifier("notice.status")
        }
        if model.testShare {
            Text(L.t("status.shareReady")).accessibilityIdentifier("share.requested")
        }
        if model.testReview {
            Text(L.t("status.review")).accessibilityIdentifier("review.requested")
        }
    }
}

extension UTType {
    static let growthLetter = UTType(exportedAs: "com.hgsldswk.growthletter", conformingTo: .data)
}
