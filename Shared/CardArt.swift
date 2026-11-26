import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum CardArt {
    static let size = CGSize(width: 1080, height: 1350)

    static func make(count: Int, nickname: String?, milestone: Milestone?, storeURL: URL?) throws -> UIImage {
        let link = storeURL ?? Launch.previewURL
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let raw = filter.outputImage else { throw GrowthError.storage }
        let scale = floor(232 / raw.extent.width)
        let output = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let code = CIContext().createCGImage(output, from: output.extent) else { throw GrowthError.storage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let serif = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title1).withDesign(.serif)
            ?? UIFont.systemFont(ofSize: 68, weight: .semibold).fontDescriptor
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let ctx = renderer.cgContext
            ctx.setFillColor(DesignColor.sheet.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setStrokeColor(DesignColor.line.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(CGRect(x: 55, y: 55, width: 970, height: 1240))

            let envelope = CGRect(x: 150, y: 150, width: 780, height: 305)
            ctx.setFillColor(DesignColor.tint.cgColor)
            ctx.fill(envelope)
            ctx.stroke(envelope)
            ctx.move(to: CGPoint(x: 150, y: 150))
            ctx.addLine(to: CGPoint(x: 540, y: 364))
            ctx.addLine(to: CGPoint(x: 930, y: 150))
            ctx.strokePath()
            ctx.setFillColor(DesignColor.accent.cgColor)
            ctx.fillEllipse(in: CGRect(x: 480, y: 304, width: 120, height: 120))
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.strokeEllipse(in: CGRect(x: 491, y: 315, width: 98, height: 98))

            func text(_ value: String, y: CGFloat, height: CGFloat, font: UIFont) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                (value as NSString).draw(in: CGRect(x: 95, y: y, width: 890, height: height),
                    withAttributes: [.font: font, .foregroundColor: DesignColor.ink, .paragraphStyle: paragraph])
            }

            let title = milestone == .firstBirthday ? L.t("card.birthday") : L.f("card.number", count)
            text(title, y: 535, height: 200, font: UIFont(descriptor: serif, size: 75))
            if let nickname { text(nickname, y: 745, height: 105, font: UIFont(descriptor: serif, size: 44)) }

            UIColor.white.setFill()
            ctx.fill(CGRect(x: 380, y: 857, width: 320, height: 300))
            ctx.interpolationQuality = .none
            let codeSize = CGFloat(code.width)
            UIImage(cgImage: code).draw(in: CGRect(x: floor((1080 - codeSize) / 2), y: floor(1007 - codeSize / 2),
                                                  width: codeSize, height: codeSize))
            text(L.t(storeURL == nil ? "card.qr.preview" : "card.qr.download"), y: 1165, height: 38, font: .systemFont(ofSize: 25))
            text(L.t("card.tags"), y: 1218, height: 45, font: .systemFont(ofSize: 27, weight: .semibold))
        }
    }
}
