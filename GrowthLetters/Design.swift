import ImageIO
import PhotosUI
import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(uiColor: DesignColor.accent)
    static let accentInk = Color(uiColor: DesignColor.accentInk)
    static let paper = Color(uiColor: DesignColor.paper)
    static let sheet = Color(uiColor: DesignColor.sheet)
    static let desk = Color(uiColor: DesignColor.desk)
    static let ink = Color(uiColor: DesignColor.ink)
    static let muted = Color(uiColor: DesignColor.muted)
    static let line = Color(uiColor: DesignColor.line)
    static let tint = Color(uiColor: DesignColor.tint)
}

struct ScreenTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.largeTitle, design: .serif).weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LetterPaper: ViewModifier {
    var tint = Theme.sheet

    func body(content: Content) -> some View {
        content.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(Theme.line).allowsHitTesting(false) }
    }
}

struct LetterButton: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(primary ? .system(.title3, design: .default).weight(.bold) : .subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: primary ? 52 : 46)
            .foregroundStyle(primary ? Color.white : Theme.ink)
            .background(primary ? Theme.accent : Theme.sheet, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(primary ? Theme.accent : Theme.line).allowsHitTesting(false) }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Action: View {
    let title: String
    let id: String
    var primary = false
    let run: () -> Void

    var body: some View {
        Button(action: run) { Text(title) }
            .buttonStyle(LetterButton(primary: primary))
            .accessibilityIdentifier(id)
    }
}

struct TextAction: View {
    let title: String
    let id: String
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, 4).frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct ChildChoices: View {
    var model: AppModel
    var inComposer = false
    var selection: UUID? = nil
    var choose: ((UUID) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(model.state.children.enumerated()), id: \.element.id) { index, child in
                    let selected = child.id == (selection ?? model.active.id)
                    Button {
                        if let choose { choose(child.id) }
                        else { model.select(child.id) }
                    } label: {
                        Text(inComposer ? L.f("child.for", child.name) : child.name)
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 13).frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(selected ? Theme.accentInk : Theme.ink)
                            .background(selected ? Theme.tint : Theme.sheet, in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line).allowsHitTesting(false) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("child.\(index)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("child.choices")
    }
}

struct PaperEditor: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var id = "letter.body"
    var placeholder = L.t("write.placeholder")
    var minHeight: CGFloat = 152

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(.system(.body, design: .serif))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 9).padding(.leading, 5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .serif))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight, idealHeight: minHeight + 20)
                .focused(focus)
                .accessibilityLabel(L.t("write.bodyLabel"))
                .accessibilityIdentifier(id)
        }
    }
}

struct CivilDatePicker: View {
    var title: String
    @Binding var day: CivilDay
    var id: String
    var range: ClosedRange<Date> = CivilDay(1900, 1, 1).date()...CivilDay(2199, 12, 31).date()

    var body: some View {
        DatePicker(title, selection: Binding(
            get: {
                let date = day.date()
                return min(max(date, range.lowerBound), range.upperBound)
            },
            set: { day = CivilDay($0) }
        ), in: range, displayedComponents: .date)
        .environment(\.calendar, CivilDay.calendar())
        .accessibilityIdentifier(id)
        .frame(minHeight: 44)
    }
}

struct PhotoControl: View {
    var hasPhoto: Bool
    var id: String
    var busy: Binding<Bool>
    var presented: Binding<Bool>? = nil
    var onPhoto: (Data) -> Void
    var onRemove: () -> Void
    var failed: () -> Void
    @State private var selected: PhotosPickerItem?
    @State private var pickerOpen = false

    var body: some View {
        HStack {
            Button { (presented ?? $pickerOpen).wrappedValue = true } label: {
                Label(L.t(hasPhoto ? "photo.change" : "photo.add"), systemImage: "photo")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accentInk)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
            .disabled(busy.wrappedValue)
            Spacer()
            if busy.wrappedValue { ProgressView().accessibilityLabel(L.t("photo.loading")) }
            if hasPhoto { TextAction(title: L.t("photo.remove"), id: id + ".remove", run: onRemove).disabled(busy.wrappedValue) }
        }
        .photosPicker(isPresented: presented ?? $pickerOpen, selection: $selected, matching: .images)
        .onChange(of: selected) { _, item in
            guard let item else { return }
            busy.wrappedValue = true
            Task {
                defer {
                    busy.wrappedValue = false
                    selected = nil
                }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw GrowthError.photo }
                    onPhoto(try await Task.detached { try PhotoCodec.clean(data) }.value)
                } catch { failed() }
            }
        }
    }
}

struct StoredPhoto: View {
    let id: UUID
    var model: AppModel
    var thumbnail = false
    @State private var picture: UIImage?

    var body: some View {
        Group {
            if let picture {
                Image(uiImage: picture).resizable()
                    .aspectRatio(contentMode: thumbnail ? .fill : .fit)
                    .accessibilityLabel(L.t("photo.attachment"))
                    .accessibilityIdentifier(thumbnail ? "letter.thumbnail" : "letter.photo")
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(width: thumbnail ? 59 : nil, height: thumbnail ? 49 : nil)
        .frame(maxWidth: thumbnail ? nil : .infinity)
        .frame(maxHeight: thumbnail ? nil : 300)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: id) {
            picture = nil
            guard let data = await model.photo(id) else { return }
            let maxSize = thumbnail ? 136 : 1080
            let decoded = await Task.detached { Self.thumbnail(data, maxSize: maxSize) }.value
            if !Task.isCancelled { picture = decoded }
        }
    }

    nonisolated static func thumbnail(_ data: Data, maxSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
