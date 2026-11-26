import SwiftUI
import UIKit

struct BookView: View {
    enum RangeChoice: String, CaseIterable, Identifiable {
        case all, latestYear, custom
        var id: String { rawValue }
    }

    private struct Selection: Hashable {
        var range = RangeChoice.all
        var paper = PaperSize.a4
        var start = CivilDay.today
        var end = CivilDay.today
        var sample = false
    }

    let model: AppModel
    @State private var selection = Selection()
    @State private var plan: BookPlan?
    @State private var page = 0
    @State private var image: UIImage?
    @State private var loading = true
    @State private var previewError: String?
    @State private var generation = UUID()

    private var count: Int { plan?.count ?? 0 }

    var body: some View {
        DetailPage(model: model, title: L.t("book.title"),
                   subtitle: selection.sample ? L.t("book.example") : nil) {
            VStack(spacing: 5) {
                if let image {
                    Image(uiImage: image)
                        .resizable().scaledToFit().frame(maxHeight: 279)
                        .background(Theme.sheet)
                        .shadow(color: Theme.ink.opacity(0.13), radius: 5, x: 3, y: 4)
                        .accessibilityLabel(L.t(page == 0 ? "book.cover" : "book.preview"))
                        .accessibilityIdentifier("book.preview.image")
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if let previewError {
                    Text(previewError).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, minHeight: 120)
                }
                if count > 0 {
                    HStack {
                        pageButton(-1, id: "book.previous", icon: "chevron.left", key: "book.previous").disabled(page <= 0)
                        Spacer()
                        Text(L.f("book.page", page + 1, count)).font(.caption).monospacedDigit()
                            .accessibilityIdentifier("book.page")
                        Spacer()
                        pageButton(1, id: "book.next", icon: "chevron.right", key: "book.next").disabled(page + 1 >= count)
                    }
                }
            }.modifier(LetterPaper(tint: Theme.desk))

            if !selection.sample {
                VStack(spacing: 4) {
                    Picker(L.t("book.range"), selection: $selection.range) {
                        ForEach(RangeChoice.allCases) { Text(L.t("range.\($0.rawValue)")).tag($0) }
                    }.accessibilityIdentifier("book.range").frame(minHeight: 44)
                    if selection.range == .custom {
                        CivilDatePicker(title: L.t("book.start"), day: $selection.start, id: "book.start")
                        CivilDatePicker(title: L.t("book.end"), day: $selection.end, id: "book.end")
                    }
                    Divider()
                    Picker(L.t("book.paper"), selection: $selection.paper) {
                        ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("book.paper").frame(minHeight: 44)
                }.modifier(LetterPaper())
            }
            Action(title: L.t("book.pdf"), id: "book.pdf", primary: true) {
                if model.requirePro(), let plan { Task { await model.export { ShareRequest(files: [try plan.pdf()]) } } }
            }.disabled(model.exporting || (!selection.sample && plan == nil))
            Action(title: L.t("book.images"), id: "book.images") {
                if model.requirePro(), let plan { Task { await model.export { ShareRequest(files: try plan.images()) } } }
            }.disabled(model.exporting || (!selection.sample && plan == nil))
            if model.exporting {
                ProgressView(L.t("book.exporting"))
                TextAction(title: L.t("action.cancel"), id: "book.cancel") { model.cancelExport() }
            }
        }
        .onAppear {
            model.updateClock()
            selection.sample = !model.hasPro
            selection.start = model.letters.last?.day ?? model.today
            selection.end = model.letters.first?.day ?? model.today
        }
        .onChange(of: model.hasPro) { _, new in selection.sample = !new }
        .task(id: selection) { await build(selection) }
        .task(id: "\(generation)-\(page)") { await showPage(page) }
    }

    func pageButton(_ step: Int, id: String, icon: String, key: String) -> some View {
        Button { page += step } label: {
            Image(systemName: icon).frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L.t(key)).accessibilityIdentifier(id)
    }

    private func build(_ selection: Selection) async {
        loading = true
        previewError = nil
        plan = nil
        image = nil
        page = 0
        let child = selection.sample ? Child(nickname: "Mia", birthday: CivilDay(2024, 8, 23)) : model.active
        let letters: [Letter]
        if selection.sample {
            letters = [Letter(childID: child.id, day: CivilDay(2026, 11, 23), body: L.t("sample.0"))]
        } else {
            let all = model.letters
            switch selection.range {
            case .all: letters = all
            case .latestYear: letters = all.filter { $0.day.year == all.first?.day.year }
            case .custom: letters = all.filter { $0.day >= selection.start && $0.day <= selection.end }
            }
        }
        do {
            let source: ([Letter], BookPhotos?)
            if selection.sample { source = (letters, nil) }
            else {
                let staged = try await model.stageBook(letters)
                source = (staged.0, staged.1)
            }
            let work = Task.detached { try BookPlan(child: child, letters: source.0, paper: selection.paper, photos: source.1) }
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled else { return }
            plan = result
            generation = UUID()
        } catch {
            guard !Task.isCancelled else { return }
            previewError = model.message(error, fallback: .storage)
        }
        if !Task.isCancelled { loading = false }
    }

    private func showPage(_ page: Int) async {
        guard let plan, (0..<plan.count).contains(page) else { return }
        let result = await Task.detached { plan.preview(page: page) }.value
        if !Task.isCancelled { image = result }
    }
}
