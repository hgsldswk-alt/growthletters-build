import Foundation
import Observation
import StoreKit
import SwiftUI
import UIKit
import WidgetKit

@MainActor
@Observable
final class AppModel {
    enum Tab: String, CaseIterable { case write, letters, receive }
    enum Route: Hashable {
        case settings, child(Bool), read(UUID), edit(UUID), book, reminder, compose, incoming, card(Int, Milestone?), paywall
    }

    var state = Library()
    var drafts: [UUID: Draft] = [:]
    var tab: Tab = .write {
        didSet { if tab != oldValue { reviewOpportunity.cancel() } }
    }
    var path: [Route] = [] {
        didSet {
            if !path.isEmpty { reviewOpportunity.cancel() }
            else if !oldValue.isEmpty { resumeFreeWriting() }
        }
    }
    var ready = false
    var writing = false
    var photoBusy = false
    var exporting = false
    var purchasing = false
    var morning = Date()
    var entitlement = Entitlement()
    var products: [String: Product] = [:]
    var error: String? {
        didSet { if error != nil { reviewOpportunity.cancel() } }
    }
    var status: String?
    var saveFeedback: Set<Milestone> = []
    var incoming: IncomingLetter?
    var incomingTarget: UUID?
    var restorePreview: Backup?
    var shareRequest: ShareRequest?
    var testShare = false
    var testReview = false
    var reviewOpportunity = ReviewOpportunity()
    var editorFocused = false {
        didSet { if editorFocused { reviewOpportunity.cancel() } }
    }
    var datePickerOpen = false {
        didSet { if datePickerOpen { reviewOpportunity.cancel() } }
    }
    var photoPickerOpen = false {
        didSet { if photoPickerOpen { reviewOpportunity.cancel() } }
    }

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let access = StoreAccess()
    @ObservationIgnored private let reminders = Reminders()
    @ObservationIgnored private var stagedPhotos: [UUID: Data] = [:]
    @ObservationIgnored private var draftTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingDraftWrites: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var draftRevision = 0
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<ShareRequest, Error>?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var pendingReminder: UUID?
    @ObservationIgnored private var opened = false
    @ObservationIgnored private var cleanedExports = false
    @ObservationIgnored private var reviewReserving = false
    @ObservationIgnored private var storeUpdates: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    init() {
        let base = URL.applicationSupportDirectory
        let testID = ProcessInfo.processInfo.environment["GL_TEST_ID"].flatMap(UUID.init(uuidString:))
        let testFolder = testID.map { base.appendingPathComponent("GrowthLettersUITest-\($0.uuidString)", isDirectory: true) }
        let folder = Launch.uiTesting ? testFolder : base.appendingPathComponent("GrowthLetters", isDirectory: true)
        store = LibraryStore(folder: folder)
    }

    var active: Child { state.active }
    var letters: [Letter] { state.letters(for: active.id) }
    var hasPro: Bool { entitlement.hasPro(at: morning) }
    var canWrite: Bool { hasPro || active.id == state.primaryID }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    var today: CivilDay {
        Launch.uiTesting && Launch.args.contains("-seed") ? CivilDay(2026, 11, 23) : .today
    }

    var draft: Draft { drafts[active.id] ?? Draft(day: today) }

    func boot() async {
        guard !opened else { return }
        opened = true
        do {
            if !cleanedExports {
                await Task.detached { TransferFiles.cleanAbandoned() }.value
                cleanedExports = true
            }
            async let cached = access.load()
            let seed = await Task.detached { Self.fixture() }.value
            let library = try await store.load(seed: seed.0, seedPhotos: seed.1, resetTestData: Launch.uiTesting && Launch.args.contains("-reset"))
            state = library
            drafts = library.drafts
            entitlement = await cached
            updateClock()
            if !hasPro {
                let freeChild = state.primaryID
                state.activeID = freeChild
            }
            ensureDraft(active.id)
            ready = true
            synchronize()
            await refreshAnniversaries()
            if Launch.uiTesting && Launch.args.contains("-paywall") { path = [.paywall] }
            if let pendingURL {
                self.pendingURL = nil
                handle(pendingURL)
            }
            if let pendingReminder {
                self.pendingReminder = nil
                openReminder(pendingReminder)
            }
            guard !Launch.uiTesting else { return }
            listenForTransactions()
            await refreshAccess()
        } catch {
            opened = false
            self.error = GrowthError.storage.message
        }
    }

    private nonisolated static func fixture() -> (Library, [UUID: Data]) {
        guard Launch.uiTesting && Launch.args.contains("-seed") else { return (Library(), [:]) }
        let mia = Child(nickname: "Mia", birthday: Launch.args.contains("-no-birthday") ? nil :
                        CivilDay(Launch.args.contains("-adult") ? 2005 : 2024, 8, 23), gender: .girl)
        let theo = Child(nickname: "Theo", birthday: CivilDay(2022, 7, 6), gender: .boy)
        var sample = Library(children: [mia, theo])
        if Launch.args.contains("-active-theo") { sample.activeID = theo.id }
        if Launch.args.contains("-many-children") {
            sample.children += ["Charlotte", "Matilda", "Theodore", "Valentina", "Zoe"].map { Child(nickname: $0) }
        }
        var photos: [UUID: Data] = [:]
        if let url = samplePhotoURL(),
           let data = try? Data(contentsOf: url), let photo = try? PhotoCodec.clean(data) {
            photos[UUID()] = photo
        }
        let photo = photos.keys.first
        let dates = [CivilDay(2026, 11, 23), CivilDay(2026, 10, 31), CivilDay(2026, 9, 23),
                     CivilDay(2026, 8, 12), CivilDay(2026, 6, 19), CivilDay(2026, 5, 3),
                     CivilDay(2026, 3, 2), CivilDay(2026, 1, 12), CivilDay(2025, 11, 11), CivilDay(2025, 8, 23)]
        let count = Launch.args.contains("-nine") ? 9 : 10
        sample.letters = dates.prefix(count).enumerated().map { index, day in
            Letter(childID: mia.id, day: day, body: L.t("sample.\(index)"), photo: index == 0 ? photo : nil,
                   cachedSummary: index == 0 ? L.t("sample.title") : nil)
        }
        if count == 10 { sample.milestones[mia.id] = [.tenth, .firstBirthday] }
        if Launch.args.contains("-screenshots") {
            sample.drafts[mia.id] = Draft(day: dates[0], body: L.t("sample.0"), photo: photo)
        }
        if Launch.args.contains("-review") {
            sample.review.days = [CivilDay(2026, 11, 20), CivilDay(2026, 11, 21)]
        }
        return (sample, photos)
    }

    nonisolated static func samplePhotoURL() -> URL? {
        Bundle.main.url(forResource: "puddle", withExtension: "jpg")
            ?? Bundle.main.url(forResource: "puddle", withExtension: "jpg", subdirectory: "Fixtures")
    }

    func select(_ id: UUID) {
        guard ready, !writing, id != active.id, state.children.contains(where: { $0.id == id }) else { return }
        reviewOpportunity.cancel()
        persistDraft(active.id)
        state.activeID = id
        saveFeedback = []
        status = nil
        ensureDraft(id)
        let previous = selectionTask
        selectionTask = Task {
            await previous?.value
            guard state.activeID == id else { return }
            do { try await store.change { $0.activeID = id } }
            catch { self.error = GrowthError.storage.message }
            synchronize()
        }
    }

    func show(_ route: Route) {
        guard ready, !writing else { return }
        status = nil
        testShare = false
        path.append(route)
    }

    func back() {
        guard !writing, !path.isEmpty else { return }
        path.removeLast()
        status = nil
        testShare = false
    }

    func switchTab(_ newTab: Tab) {
        guard !writing else { return }
        if newTab != tab { persistDraft(active.id) }
        tab = newTab
        resumeFreeWriting()
        status = nil
        testShare = false
    }

    private func ensureDraft(_ id: UUID) {
        if drafts[id] == nil { drafts[id] = Draft(day: today) }
    }

    func refreshEmptyDates() {
        for id in drafts.keys {
            if let value = drafts[id], value.body.isEmpty, value.photo == nil, value.hasChosenDay != true, value.day != today {
                drafts[id] = Draft(id: value.id, day: today)
            }
        }
    }

    func updateDraft(_ change: (inout Draft) -> Void) {
        guard ready, !writing else { return }
        let id = active.id
        var next = draft
        change(&next)
        drafts[id] = next
        scheduleDraft(id)
    }

    func attachDraftPhoto(_ data: Data, to child: UUID) {
        guard var next = drafts[child], !writing else { return }
        let id = UUID()
        next.photo = id
        stagedPhotos = stagedPhotos.filter { $0.key != drafts[child]?.photo }
        stagedPhotos[id] = data
        drafts[child] = next
        persistDraft(child)
    }

    func removeDraftPhoto() {
        if let photo = draft.photo { stagedPhotos[photo] = nil }
        updateDraft { $0.photo = nil }
        persistDraft(active.id)
    }

    private func scheduleDraft(_ id: UUID) {
        draftTasks[id]?.cancel()
        draftTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persistDraft(id)
        }
    }

    func flushDrafts(inBackground: Bool) {
        for id in drafts.keys { persistDraft(id) }
        guard inBackground, !Launch.uiTesting, !pendingDraftWrites.isEmpty else { return }
        let writes = Array(pendingDraftWrites.values)
        let application = UIApplication.shared
        let background = application.beginBackgroundTask(withName: "GrowthLetters.Drafts") {
            for task in writes { task.cancel() }
        }
        guard background != .invalid else { return }
        Task {
            for task in writes { await task.value }
            application.endBackgroundTask(background)
        }
    }

    private func persistDraft(_ child: UUID) {
        draftTasks[child]?.cancel()
        draftTasks[child] = nil
        guard ready, let value = drafts[child] else { return }
        let photo = value.photo.flatMap { id in stagedPhotos[id].map { [id: $0] } } ?? [:]
        let today = today
        draftRevision += 1
        let revision = draftRevision
        pendingDraftWrites[child] = Task {
            do {
                try await store.persistDraft(value, for: child, today: today, revision: revision, photos: photo)
                for id in photo.keys { stagedPhotos[id] = nil }
            } catch { self.error = GrowthError.storage.message }
        }
    }

    func photo(_ id: UUID) async -> Data? {
        if let data = stagedPhotos[id] { return data }
        return try? await store.photo(id)
    }

    func saveLetter() async {
        guard ready, !writing else { return }
        reviewOpportunity.cancel()
        updateClock()
        guard canWrite else { requirePro(); return }
        let child = active.id
        let draft = self.draft
        guard Letter.validBody(draft.body) else { self.error = GrowthError.invalid.message; return }
        draftTasks[child]?.cancel()
        draftTasks[child] = nil
        writing = true
        defer {
            writing = false
            resumeFreeWriting()
        }
        error = nil
        let letter = Letter(id: draft.id, childID: child, day: draft.day, body: draft.body, photo: draft.photo)
        let now = Launch.uiTesting && Launch.args.contains("-review") ? today.date() : Date()
        let civilToday = today
        let prior = state.milestones[child, default: []]
        let photo = draft.photo.flatMap { id in stagedPhotos[id].map { [id: $0] } } ?? [:]
        do {
            let saved = try await store.change(photos: photo) { library in
                guard !library.letters.contains(where: { $0.id == letter.id }) else { return }
                _ = try library.add(letter, checkMilestones: true)
                if library.birthdayMilestones(on: civilToday).contains(child) {
                    library.milestones[child, default: []].insert(.firstBirthday)
                }
                library.drafts[child] = nil
                library.review.record(now)
            }
            apply(saved)
            drafts[child] = Draft(day: today)
            for id in photo.keys { stagedPhotos[id] = nil }
            saveFeedback = state.milestonePrompts ? state.milestones[child, default: []].subtracting(prior) : []
            status = L.t("status.saved")
            let reviewEligible = state.review.eligible(version, idle: path.isEmpty && tab == .write && error == nil)
            reviewOpportunity.saved(eligible: reviewEligible)
        } catch { self.error = GrowthError.storage.message }
    }

    func saveChild(name: String, birthday: CivilDay?, gender: Child.Gender?, new: Bool) async {
        updateClock()
        if new && !hasPro { requirePro(); return }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        let newChild = Child(nickname: name, birthday: birthday, gender: gender)
        let current = active.id
        if await change({ library in
            if new {
                guard library.children.count < 1_000 else { throw GrowthError.tooLarge }
                library.children.append(newChild)
                library.activeID = newChild.id
            } else if let index = library.children.firstIndex(where: { $0.id == current }) {
                library.children[index].nickname = name
                library.children[index].birthday = birthday
                library.children[index].gender = gender
            }
        }, keepActive: !new) {
            ensureDraft(active.id)
            back()
        }
    }

    func setPrimary(_ id: UUID) async {
        _ = await change { $0.primaryID = id }
    }

    func setMilestones(_ enabled: Bool) async {
        _ = await change { $0.milestonePrompts = enabled }
    }

    func setWidget(_ enabled: Bool) async {
        _ = await change { $0.widgetEnabled = enabled }
    }

    func edit(_ letter: Letter, photo: Data?) async {
        guard Letter.validBody(letter.body) else { self.error = GrowthError.invalid.message; return }
        var updated = letter
        updated.revision = UUID()
        let record = updated
        let photos = letter.photo.flatMap { id in photo.map { [id: $0] } } ?? [:]
        if await change(photos: photos, { library in
            guard let index = library.letters.firstIndex(where: { $0.id == letter.id }) else { throw GrowthError.invalid }
            library.letters[index] = record
        }) { back() }
    }

    func delete(_ letter: Letter) async {
        if await change({ library in
            guard let index = library.letters.firstIndex(where: { $0.id == letter.id }) else { return }
            library.undoLetter = library.letters.remove(at: index)
            library.deletedIDs.insert(letter.id)
        }) {
            back()
            status = L.t("status.deleted")
        }
    }

    func undoDelete() async {
        if await change({ library in
            guard let prior = library.undoLetter else { return }
            library.letters.append(prior)
            library.deletedIDs.remove(prior.id)
            library.undoLetter = nil
        }) {
            status = L.t("status.undone")
        }
    }

    func setReminder(_ day: CivilDay?, enabled: Bool) async {
        guard !writing else { return }
        updateClock()
        guard hasPro else { requirePro(); return }
        let id = active.id
        var allowed = false
        var permissionFailed = false
        if enabled, day != nil {
            writing = true
            do { allowed = try await reminders.permission() }
            catch { permissionFailed = true }
            writing = false
        }
        let reminder = day.map { OpeningReminder(day: $0, enabled: enabled) }
        if await change({ $0.reminders[id] = reminder }) {
            back()
            if enabled && !allowed {
                self.error = L.t(permissionFailed ? "error.notification" : "reminder.denied")
            }
        }
    }

    func handle(_ url: URL) {
        guard ready else { pendingURL = url; return }
        if url.scheme == "growthletters", url.host == "write" {
            path = []
            switchTab(.write)
            return
        }
        guard url.isFileURL, url.pathExtension.lowercased() == "growthletter" else { return }
        Task { await openFile(url) }
    }

    func openReminder(_ id: UUID) {
        guard ready else { pendingReminder = id; return }
        guard state.children.contains(where: { $0.id == id }) else { return }
        select(id)
        tab = .letters
        path = [.book]
    }

    func receiveCode(_ code: String) async {
        guard !writing else { return }
        let target = active.id
        do { preview(try await Task.detached { try IncomingLetter.read(code: code) }.value, target: target) }
        catch { self.error = message(error) }
    }

    func openFile(_ url: URL) async {
        guard !writing else { return }
        let target = active.id
        do {
            let letter = try await Task.detached {
                try IncomingLetter.read(file: TransferFiles.read(url, limit: IncomingLetter.fileLimit))
            }.value
            preview(letter, target: target)
        } catch { self.error = message(error) }
    }

    func openFixtureLetter() async {
        guard Launch.uiTesting else { return }
        do {
            let url = try await Task.detached {
                guard let source = Self.samplePhotoURL() else { throw GrowthError.photo }
                let photo = try PhotoCodec.clean(Data(contentsOf: source))
                let letter = IncomingLetter(day: CivilDay(2026, 11, 21), body: L.t("sample.family"),
                                            sender: L.t("sample.grandma"), photo: photo)
                return try TransferFiles.write(JSONEncoder().encode(letter), named: "FamilyLetter.growthletter")
            }.value
            await openFile(url)
            ShareRequest(files: [url]).cleanup()
        } catch { self.error = message(error) }
    }

    private func preview(_ letter: IncomingLetter, target: UUID) {
        guard !state.received.contains(letter.id) else { self.error = GrowthError.duplicate.message; return }
        incoming = letter
        incomingTarget = letter.suggestedChild(in: state.children) ?? target
        tab = .receive
        path = [.incoming]
    }

    func acceptIncoming() async {
        guard let incoming, let target = incomingTarget, state.children.contains(where: { $0.id == target }) else { return }
        guard requirePro() else { return }
        let photoID = incoming.photo.map { _ in UUID() }
        let photos = photoID.flatMap { id in incoming.photo.map { [id: $0] } } ?? [:]
        let letter = Letter(childID: target, day: incoming.day, body: incoming.body, sender: incoming.sender,
                            sourceID: incoming.id, photo: photoID)
        if await change(photos: photos, { _ = try $0.add(letter, checkMilestones: true) }) {
            select(target)
            self.incoming = nil
            incomingTarget = nil
            path = []
            tab = .letters
            status = L.t("status.imported")
        }
    }

    func backup() async {
        let access = entitlement
        let store = store
        await export {
            let data = try await store.backup(entitlement: access)
            let file = try TransferFiles.write(data, named: "GrowthLetters.zip")
            return ShareRequest(files: [file])
        }
    }

    func prepareRestore(_ url: URL) async {
        do {
            restorePreview = try await Task.detached { try Backup.read(TransferFiles.read(url, limit: Backup.limit)) }.value
        } catch { self.error = message(error) }
    }

    func openFixtureBackup() async {
        guard Launch.uiTesting else { return }
        let store = store
        let entitlement = entitlement
        do {
            let url = try await Task.detached {
                let data = try await store.backup(entitlement: entitlement)
                return try TransferFiles.write(data, named: "GrowthLetters.zip")
            }.value
            await prepareRestore(url)
            ShareRequest(files: [url]).cleanup()
        } catch { self.error = message(error) }
    }

    func restoreBackup() async {
        guard let preview = restorePreview else { return }
        let backup = preview.withFreshPhotoIDs()
        if await change(photos: backup.photos, { try backup.merge(into: &$0) }, keepActive: false) {
            restorePreview = nil
            ensureDraft(active.id)
            entitlement = await access.mergeTrial(backup.manifest.trialStart)
            updateClock()
            synchronize()
            status = L.t("status.restored")
        }
    }

    func fullLetter(_ letter: Letter) async throws -> Letter { try await store.fullLetter(letter) }

    func search(_ query: String, in letters: [Letter]) async throws -> Set<UUID> {
        let bodies = try await store.search(query, in: letters)
        let senders = letters.filter { $0.sender?.localizedStandardContains(query) == true }.map(\.id)
        return bodies.union(senders)
    }

    func stageBook(_ letters: [Letter]) async throws -> ([Letter], BookPhotos) {
        try await store.stageBook(letters)
    }

    func export(_ operation: @escaping @Sendable () async throws -> ShareRequest) async {
        guard !exporting, shareRequest == nil else { return }
        reviewOpportunity.cancel()
        exporting = true
        testShare = false
        let task = Task.detached(operation: operation)
        exportTask = task
        defer {
            exportTask = nil
            exporting = false
        }
        do {
            let request = try await task.value
            if task.isCancelled { request.cleanup() }
            else { share(request) }
        } catch is CancellationError {
        } catch { self.error = message(error) }
    }

    func cancelExport() { exportTask?.cancel() }

    func shareCard(count: Int, nickname: String? = nil, milestone: Milestone? = nil) async {
        await export {
            let image = try CardArt.make(count: count, nickname: nickname, milestone: milestone, storeURL: Launch.storeURL)
            guard let bytes = image.pngData() else { throw GrowthError.storage }
            let file = try TransferFiles.write(bytes, named: "GrowthLetterCard.png")
            return ShareRequest(text: L.t("card.caption"), files: [file])
        }
    }

    func share(_ request: ShareRequest) {
        reviewOpportunity.cancel()
        if Launch.uiTesting {
            request.cleanup()
            testShare = true
        } else {
            shareRequest = request
        }
    }

    @discardableResult
    func requirePro() -> Bool {
        updateClock()
        if hasPro { return true }
        if path.last != .paywall { show(.paywall) }
        return false
    }

    func updateClock() {
        morning = .now
        expiry?.cancel()
        let wait = entitlement.trialEnd.timeIntervalSince(morning)
        if wait > 0 && !entitlement.purchasedPro {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait + 0.1))
                guard !Task.isCancelled else { return }
                self?.updateClock()
                self?.resumeFreeWriting()
                self?.synchronize()
            }
        }
    }

    func refreshAccess() async {
        entitlement = await access.refresh()
        updateClock()
        resumeFreeWriting()
        synchronize()
    }

    private func resumeFreeWriting() {
        guard ready, !hasPro, tab == .write, path.isEmpty, !writing else { return }
        select(state.primaryID)
    }

    func refreshAnniversaries() async {
        let day = today
        guard !state.birthdayMilestones(on: day).isEmpty else { return }
        _ = await change { library in
            for child in library.birthdayMilestones(on: day) {
                library.milestones[child, default: []].insert(.firstBirthday)
            }
        }
    }

    func loadProducts() async {
        guard !Launch.uiTesting, !Launch.isFree else { return }
        do { products = Dictionary(uniqueKeysWithValues: try await Product.products(for: [Launch.proID, Launch.trialID]).map { ($0.id, $0) }) }
        catch { self.error = GrowthError.purchase.message }
    }

    func purchase(_ id: String) async {
        guard !purchasing, !Launch.isFree else { return }
        guard let product = products[id] else { self.error = GrowthError.purchase.message; return }
        purchasing = true
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard await access.accept(result), case .verified(let transaction) = result else { throw GrowthError.purchase }
                await transaction.finish()
                await refreshAccess()
                status = L.t(id == Launch.proID ? "status.purchased" : "status.claimed")
            case .pending: status = L.t("status.pending")
            case .userCancelled: break
            @unknown default: throw GrowthError.purchase
            }
        } catch { self.error = GrowthError.purchase.message }
    }

    func restorePurchase() async {
        guard !purchasing, !Launch.isFree else { return }
        purchasing = true
        defer { purchasing = false }
        do {
            if !Launch.uiTesting { try await AppStore.sync() }
            await refreshAccess()
            status = L.t(entitlement.purchasedPro ? "status.purchased" : "status.noPurchase")
        } catch { self.error = GrowthError.purchase.message }
    }

    private func listenForTransactions() {
        storeUpdates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                if await self.access.accept(result), case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.refreshAccess()
                }
            }
        }
    }

    private func change(photos: [UUID: Data] = [:], _ operation: @escaping @Sendable (inout Library) throws -> Void,
                        keepActive: Bool = true) async -> Bool {
        guard ready, !writing else { return false }
        writing = true
        defer { writing = false }
        do {
            apply(try await store.change(photos: photos, operation), keepActive: keepActive)
            return true
        } catch {
            self.error = message(error, fallback: .storage)
            return false
        }
    }

    private func apply(_ library: Library, keepActive: Bool = true) {
        let id = state.activeID
        state = library
        if keepActive && state.children.contains(where: { $0.id == id }) { state.activeID = id }
        synchronize()
    }

    private func synchronize() {
        guard ready else { return }
        if !Launch.uiTesting {
            let snapshot = state.widgetEnabled ? WidgetSnapshot(count: letters.count, opening: state.reminders[active.id]?.day.date()) : nil
            if WidgetSnapshot.read() != snapshot {
                WidgetSnapshot.set(snapshot)
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind)
            }
        }
        let snapshot = state.reminders
        let entitlement = entitlement
        Task {
            if await reminders.sync(snapshot, entitlement: entitlement) == false, state.reminders == snapshot {
                self.error = GrowthError.notification.message
            }
        }
    }

    func requestReview(for ticket: UUID, isIdle: () -> Bool, perform: () -> Void) async {
        let version = version
        guard !reviewReserving, reviewOpportunity.permits(ticket, unobstructed: isIdle()),
              state.review.eligible(version, idle: true) else { return }
        reviewReserving = true
        defer { reviewReserving = false }
        do {
            _ = try await store.change { _ = $0.review.requestedVersions.insert(version) }
            guard !Task.isCancelled, reviewOpportunity.permits(ticket, unobstructed: isIdle()) else {
                _ = try await store.change { $0.review.requestedVersions.remove(version) }
                state.review.requestedVersions.remove(version)
                return
            }
            state.review.requestedVersions.insert(version)
            reviewOpportunity.cancel()
            perform()
        } catch {
            self.error = GrowthError.storage.message
        }
    }

    func message(_ error: Error, fallback: GrowthError = .invalid) -> String {
        (error as? GrowthError ?? fallback).message
    }
}

struct ShareRequest: Identifiable, Sendable {
    let id = UUID()
    var text: String? = nil
    var files: [URL] = []

    func cleanup() {
        guard let folder = files.first?.deletingLastPathComponent(),
              folder.deletingLastPathComponent().lastPathComponent == "GrowthLetters-Exports" else { return }
        Task.detached { try? FileManager.default.removeItem(at: folder) }
    }
}
