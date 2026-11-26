import CoreText
import UIKit

enum PaperSize: String, CaseIterable, Identifiable, Sendable {
    case a4, letter
    var id: String { rawValue }
    var size: CGSize { self == .a4 ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792) }
    var title: String { L.t(self == .a4 ? "book.a4" : "book.letter") }
}

final class BookPhotos: Sendable {
    private let folder: URL

    init(folder: URL) { self.folder = folder }

    func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".jpg") }

    deinit {
        let url = folder
        Task.detached { try? FileManager.default.removeItem(at: url) }
    }
}

struct BookPlan: @unchecked Sendable {
    private static let margin: CGFloat = 55
    private static let bodyTop: CGFloat = 139
    private let size: CGSize
    private let title: String
    private let child: Child
    private let letters: [Letter]
    private let coverPhoto: UUID?
    private let photos: BookPhotos?
    private let pages: [Page]

    private struct Entry {
        let letter: Letter
        let number: Int
    }

    private enum Page {
        case cover
        case contents([Entry])
        case letter(Letter, NSAttributedString, NSRange, Bool, Bool)
    }

    var count: Int { pages.count }

    init(child: Child, letters source: [Letter], paper: PaperSize, photos: BookPhotos?) throws {
        let letters = source.sorted { ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString) }
        guard !letters.isEmpty else { throw GrowthError.noLetters }
        self.size = paper.size
        self.title = L.f("book.for", child.name)
        self.child = child
        self.letters = letters
        self.coverPhoto = letters.reversed().compactMap(\.photo).first
        self.photos = photos

        let perIndex = 19
        let indexCount = (letters.count + perIndex - 1) / perIndex
        var entries: [Entry] = []
        var bodyPages: [Page] = []
        let bodyHeight = paper.size.height - Self.bodyTop - Self.margin - 24
        let width = paper.size.width - 2 * Self.margin
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 8
        let letterFont = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
            .withDesign(.serif) ?? UIFont.systemFont(ofSize: 16).fontDescriptor, size: 16)

        for letter in letters {
            entries.append(Entry(letter: letter, number: bodyPages.count + indexCount + 2))
            let text = NSAttributedString(string: letter.body,
                attributes: [.font: letterFont, .foregroundColor: DesignColor.ink, .paragraphStyle: paragraph])
            let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
            var offset = 0
            while offset < text.length {
                try Task.checkCancellation()
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: bodyHeight), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { throw GrowthError.storage }
                let last = offset + visible.length == text.length
                let reduced = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: bodyHeight - 185), transform: nil)
                let photoFits = last && letter.photo != nil &&
                    CTFrameGetVisibleStringRange(CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), reduced, nil)).length >= visible.length
                bodyPages.append(.letter(letter, text, NSRange(location: offset, length: visible.length), offset > 0, photoFits))
                if last && letter.photo != nil && !photoFits {
                    bodyPages.append(.letter(letter, text, NSRange(location: 0, length: 0), true, true))
                }
                offset += visible.length
            }
        }
        let contents = stride(from: 0, to: entries.count, by: perIndex).map {
            Page.contents(Array(entries[$0..<min($0 + perIndex, entries.count)]))
        }
        pages = [.cover] + contents + bodyPages
    }

    func preview(page: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { draw(page, context: $0.cgContext) }
    }

    func pdf() throws -> URL {
        let folder = try TransferFiles.folder()
        let url = folder.appendingPathComponent("GrowthLetters.pdf")
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size), format: format)
        do {
            try renderer.writePDF(to: url) { renderer in
                for page in pages.indices where !Task.isCancelled {
                    autoreleasepool {
                        renderer.beginPage()
                        draw(page, context: renderer.cgContext)
                    }
                }
            }
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func images() throws -> [URL] {
        let folder = try TransferFiles.folder()
        do {
            return try pages.indices.map { index in
                try Task.checkCancellation()
                return try autoreleasepool {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 2
                    format.opaque = true
                    let png = UIGraphicsImageRenderer(size: size, format: format).pngData { draw(index, context: $0.cgContext) }
                    let url = folder.appendingPathComponent(String(format: "GrowthLetters-%04d.png", index + 1))
                    try png.write(to: url, options: [.atomic, .completeFileProtection])
                    return url
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func draw(_ index: Int, context: CGContext) {
        let m = Self.margin
        let w = size.width - 2 * m
        let muted = DesignColor.muted
        context.setFillColor(DesignColor.sheet.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        func text(_ value: String, x: CGFloat? = nil, y: CGFloat,
                  width: CGFloat? = nil, height: CGFloat = 30, font: UIFont, color: UIColor? = nil) {
            (value as NSString).draw(in: CGRect(x: x ?? m, y: y, width: width ?? w, height: height),
                                     withAttributes: [.font: font, .foregroundColor: color ?? DesignColor.ink])
        }

        func photo(_ id: UUID?, in rect: CGRect) {
            guard let id, let file = photos?.url(id), let photo = UIImage(contentsOfFile: file.path),
                  photo.size.height > 0, photo.size.width > 0 else { return }
            let scale = min(rect.width / photo.size.width, rect.height / photo.size.height)
            photo.draw(in: CGRect(origin: rect.origin, size: CGSize(width: photo.size.width * scale, height: photo.size.height * scale)))
        }

        let heading = UIFont(descriptor: UIFont.systemFont(ofSize: 28, weight: .semibold).fontDescriptor
            .withDesign(.serif) ?? UIFont.boldSystemFont(ofSize: 28).fontDescriptor, size: 28)
        let small = UIFont.systemFont(ofSize: 12)
        switch pages[index] {
        case .cover:
            let first = letters.first!.day.year
            let last = letters.last!.day.year
            let years = first == last ? String(first) : "\(first)–\(last)"
            text(years, y: 88, font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), color: DesignColor.accentInk)
            text(title, y: 135, height: 230, font: heading.withSize(49))
            text(L.f("letters.count", letters.count), y: 325, font: UIFont.systemFont(ofSize: 18), color: muted)
            photo(coverPhoto, in: CGRect(x: m, y: 390, width: w, height: size.height - 480))
        case .contents(let entries):
            text(L.t("book.contents"), y: 60, height: 45, font: heading)
            for (row, entry) in entries.enumerated() {
                let y = CGFloat(116 + row * 29)
                text(entry.letter.day.display, y: y + 2, width: 116, font: small, color: muted)
                text(entry.letter.summary, x: m + 119, y: y, width: w - 167, height: 22, font: UIFont.systemFont(ofSize: 14))
                text(String(entry.number), x: size.width - m - 37, y: y, width: 37, font: small)
            }
        case let .letter(letter, document, range, continued, showPhoto):
            text(letter.summary, y: 50, height: 54, font: heading.withSize(23))
            let age = child.historyAge(on: letter.day).map { " · " + $0 } ?? ""
            text(letter.day.display + age, y: 103, font: small, color: muted)
            if let sender = letter.sender, !sender.isEmpty {
                text(L.f("letter.from", sender), y: 120, font: small, color: muted)
            }
            if range.length > 0 {
                let h = size.height - Self.bodyTop - m - 24 - (showPhoto ? 185 : 0)
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: m, y: Self.bodyTop + h)
                context.scaleBy(x: 1, y: -1)
                let framesetter = CTFramesetterCreateWithAttributedString(document as CFAttributedString)
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil)
                CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: range.location, length: range.length), path, nil), context)
                context.restoreGState()
            }
            if showPhoto {
                let y = range.length == 0 ? Self.bodyTop : size.height - m - 205
                photo(letter.photo, in: CGRect(x: m, y: y, width: w, height: range.length == 0 ? size.height - y - m : 170))
            }
            if continued { text(L.t("book.continued"), y: size.height - m, width: 160, font: small, color: muted) }
        }
        if index > 0 { text(String(index + 1), x: size.width - m - 26, y: size.height - m, width: 26, font: small, color: muted) }
    }
}
