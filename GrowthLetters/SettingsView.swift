import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: AppModel
    @State private var restorePicker = false

    var body: some View {
        DetailPage(model: model, title: L.t("settings.title")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("settings.freeChild")).font(.headline)
                Text(L.t("settings.freeChildHelp")).font(.subheadline).foregroundStyle(Theme.muted)
                Picker(L.t("settings.freeChild"), selection: Binding(get: { model.state.primaryID }, set: { child in
                    Task { await model.setPrimary(child) }
                })) {
                    ForEach(model.state.children) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("settings.primary").frame(minHeight: 44)
            }.modifier(LetterPaper())

            VStack(alignment: .leading, spacing: 8) {
                Toggle(L.t("settings.milestones"), isOn: Binding(get: { model.state.milestonePrompts }, set: { value in
                    Task { await model.setMilestones(value) }
                })).accessibilityIdentifier("settings.milestones").frame(minHeight: 44)
                Divider()
                Toggle(L.t("settings.widget"), isOn: Binding(get: { model.state.widgetEnabled }, set: { value in
                    Task { await model.setWidget(value) }
                })).accessibilityIdentifier("settings.widget").frame(minHeight: 44)
                Text(L.t("settings.widgetHelp")).font(.caption).foregroundStyle(Theme.muted)
            }.modifier(LetterPaper())

            VStack(spacing: 9) {
                Action(title: L.t("settings.backup"), id: "settings.backup") { Task { await model.backup() } }
                    .disabled(model.exporting)
                Action(title: L.t("settings.restore"), id: "settings.restore") {
                    if Launch.uiTesting && Launch.args.contains("-fixture-restore") { Task { await model.openFixtureBackup() } }
                    else { restorePicker = true }
                }
                    .disabled(model.exporting || model.writing)
                if model.exporting {
                    ProgressView().accessibilityLabel(L.t("status.loading"))
                    TextAction(title: L.t("action.cancel"), id: "backup.cancel") { model.cancelExport() }
                }
                if let restore = model.restorePreview {
                    Text(L.f("settings.restoreCount", restore.manifest.children.count, restore.manifest.letters.count))
                        .font(.subheadline)
                    Text(L.t("settings.restoreHelp")).font(.caption).foregroundStyle(Theme.muted)
                    Action(title: L.t("settings.merge"), id: "settings.merge", primary: true) { Task { await model.restoreBackup() } }
                        .disabled(model.writing)
                    TextAction(title: L.t("action.cancel"), id: "restore.cancel") { model.restorePreview = nil }
                }
            }.modifier(LetterPaper())

            if !Launch.isFree {
                VStack(spacing: 9) {
                    Action(title: L.t("paywall.title"), id: "settings.paywall") { model.show(.paywall) }
                    Action(title: L.t("paywall.restore"), id: "settings.purchaseRestore") { Task { await model.restorePurchase() } }
                        .disabled(model.purchasing)
                }.modifier(LetterPaper())
            }

            Text(L.t("settings.privacy")).font(.footnote).foregroundStyle(Theme.muted)
        }
        .fileImporter(isPresented: $restorePicker, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): Task { await model.prepareRestore(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.error = GrowthError.invalid.message }
            }
        }
    }
}

struct ReminderView: View {
    enum Preset: String, CaseIterable, Identifiable {
        case birthday, eighteen, graduation
        var id: String { rawValue }
    }

    let model: AppModel
    @State private var selected = Preset.birthday
    @State private var day = CivilDay.today
    @State private var enabled = true
    @State private var editingCustom = false
    @State private var hasDefault = false

    private var birthday: CivilDay? { model.active.birthday }
    private var existing: OpeningReminder? { model.state.reminders[model.active.id] }

    var body: some View {
        DetailPage(model: model, title: L.t("reminder.title"), subtitle: L.f("child.for", model.active.name)) {
            if !model.hasPro {
                if let existing { Text(L.f("reminder.scheduled", existing.day.display)).modifier(LetterPaper()) }
                Text(L.t("reminder.locked")).foregroundStyle(Theme.muted)
                Action(title: L.t("paywall.title"), id: "reminder.unlock", primary: true) { _ = model.requirePro() }
            } else {
                VStack(spacing: 8) {
                    ForEach(Preset.allCases) { preset in
                        let unavailable = preset != .graduation && (birthday == nil ||
                            (preset == .eighteen && eighteenPassed))
                        Button { choose(preset) } label: {
                            HStack {
                                Text(L.t("reminder.\(preset.rawValue)")).font(.subheadline.weight(.semibold))
                                Spacer()
                                if selected == preset { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }.padding(.horizontal, 12).frame(minHeight: 46)
                                .background(selected == preset ? Theme.tint : Theme.sheet, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reminder.\(preset.rawValue)")
                        .accessibilityAddTraits(selected == preset ? .isSelected : [])
                        .accessibilityHint(preset == .eighteen && eighteenPassed ? L.t("reminder.eighteenPassed") : "")
                        .disabled(unavailable)
                        .opacity(unavailable ? 0.45 : 1)
                    }
                }.modifier(LetterPaper())
                if birthday == nil { Text(L.t("reminder.noBirthday")).font(.caption).foregroundStyle(Theme.muted) }
                if eighteenPassed {
                    Text(L.t("reminder.eighteenPassed")).font(.caption).foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("reminder.eighteen.reason")
                }
                VStack(alignment: .leading, spacing: 8) {
                    if editingCustom {
                        CivilDatePicker(title: L.t("reminder.date"), day: $day, id: "reminder.date",
                                        range: model.today.date()...CivilDay(2199, 12, 31).date())
                            .datePickerStyle(.graphical)
                    } else {
                        Text(day.display).font(.headline).accessibilityIdentifier("reminder.selectedDay")
                    }
                    Toggle(L.t("reminder.notify"), isOn: $enabled)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("reminder.notify")
                    if enabled, !model.entitlement.purchasedPro, !Launch.isFree,
                       OpeningReminder(day: day, enabled: true).delivery >= model.entitlement.trialEnd {
                        Text(L.t("reminder.afterTrial")).font(.caption).foregroundStyle(Theme.muted)
                    }
                }.modifier(LetterPaper())
                Action(title: L.t("reminder.save"), id: "reminder.save", primary: true) {
                    Task { await model.setReminder(day, enabled: enabled) }
                }.disabled(model.writing || !hasDefault || day < model.today)
                if existing != nil {
                    TextAction(title: L.t("reminder.remove"), id: "reminder.remove") {
                        Task { await model.setReminder(nil, enabled: false) }
                    }.disabled(model.writing)
                }
            }
        }
        .onAppear {
            if let existing {
                day = existing.day
                enabled = existing.enabled
                selected = presetDate(.birthday) == day ? .birthday :
                    (!eighteenPassed && presetDate(.eighteen) == day ? .eighteen : .graduation)
                hasDefault = true
            } else {
                choose(birthday == nil ? .graduation : .birthday)
            }
        }
    }

    private var eighteenPassed: Bool {
        presetDate(.eighteen).map { $0 < model.today } ?? false
    }

    private func choose(_ preset: Preset) {
        selected = preset
        editingCustom = preset == .graduation
        if let date = presetDate(preset) {
            day = date
            hasDefault = true
        } else if preset == .graduation {
            day = max(model.today, day)
            hasDefault = true
        }
    }

    private func presetDate(_ preset: Preset) -> CivilDay? {
        guard let birthday else { return nil }
        switch preset {
        case .birthday:
            let current = birthday.anniversary(model.today.year)
            return current > model.today ? current : birthday.anniversary(model.today.year + 1)
        case .eighteen: return birthday.anniversary(birthday.year + 18)
        case .graduation: return nil
        }
    }
}

struct PaywallView: View {
    let model: AppModel

    private var price: String? {
        if Launch.uiTesting && Launch.args.contains("-paywall") { return "$3.99" }
        return model.products[Launch.proID]?.displayPrice
    }

    var body: some View {
        DetailPage(model: model, title: L.t("paywall.title"), subtitle: L.t("paywall.subtitle")) {
            VStack(alignment: .leading, spacing: 13) {
                Label(L.t("paywall.books"), systemImage: "book.closed")
                Label(L.t("paywall.kids"), systemImage: "folder")
                Label(L.t("paywall.incoming"), systemImage: "envelope")
                Label(L.t("paywall.reminders"), systemImage: "calendar")
            }.font(.subheadline.weight(.semibold)).modifier(LetterPaper(tint: Theme.tint))
            Text(L.t("paywall.free")).font(.subheadline).foregroundStyle(Theme.muted)
            if model.entitlement.purchasedPro {
                Text(L.t("status.purchased")).foregroundStyle(Theme.accentInk)
            } else {
                if model.hasPro {
                    let days = max(1, Int(ceil(model.entitlement.trialEnd.timeIntervalSince(model.morning) / 86_400)))
                    Text(L.f("paywall.remaining", days)).font(.subheadline).foregroundStyle(Theme.accentInk)
                }
                Action(title: price.map { L.f("paywall.buyPrice", $0) } ?? L.t("paywall.buy"), id: "paywall.buy", primary: true) {
                    Task { await model.purchase(Launch.proID) }
                }.disabled(price == nil || model.purchasing)
                if price == nil {
                    TextAction(title: L.t("action.retry"), id: "paywall.retry") { Task { await model.loadProducts() } }
                }
                if model.entitlement.trialClaimedAt == nil &&
                    ((model.hasPro && model.products[Launch.trialID] != nil) || (Launch.uiTesting && Launch.args.contains("-paywall"))) {
                    Action(title: L.t("paywall.claim"), id: "paywall.claim") { Task { await model.purchase(Launch.trialID) } }
                        .disabled(model.purchasing)
                    Text(L.t("paywall.trialNote")).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Action(title: L.t("paywall.restore"), id: "paywall.restore") { Task { await model.restorePurchase() } }
                .disabled(model.purchasing)
        }.task { await model.loadProducts() }
    }
}
