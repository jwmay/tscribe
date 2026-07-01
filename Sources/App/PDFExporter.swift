import Foundation
import AppKit
import CoreText

/// Renders a transcript to a multi-page US-Letter PDF using Core Text pagination.
/// Uses only system frameworks — no dependencies.
enum PDFExporter {
    static func pdf(_ transcript: Transcript) -> Data {
        let content = makeAttributedString(transcript)

        let pageWidth: CGFloat = 612    // 8.5" × 72
        let pageHeight: CGFloat = 792   // 11"  × 72
        let margin: CGFloat = 54        // 0.75"
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let textRect = CGRect(x: margin, y: margin,
                              width: pageWidth - 2 * margin,
                              height: pageHeight - 2 * margin)

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        let framesetter = CTFramesetterCreateWithAttributedString(content as CFAttributedString)
        let path = CGPath(rect: textRect, transform: nil)
        let total = content.length
        var start = 0

        repeat {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(mediaBox)

            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(frame, ctx)
            let consumed = CTFrameGetVisibleStringRange(frame).length

            ctx.endPDFPage()
            if consumed <= 0 { break }   // safety: never loop forever
            start += consumed
        } while start < total

        ctx.closePDF()
        return pdfData as Data
    }

    private static func makeAttributedString(_ transcript: Transcript) -> NSAttributedString {
        let out = NSMutableAttributedString()

        out.append(NSAttributedString(string: "Transcript\n\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 20),
            .foregroundColor: NSColor.black
        ]))

        // Hanging indent so wrapped lines align under the text, not the timestamp.
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.paragraphSpacing = 6
        bodyStyle.headIndent = 72
        bodyStyle.tabStops = [NSTextTab(textAlignment: .left, location: 72)]
        bodyStyle.lineHeightMultiple = 1.1

        let tsFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11)

        for seg in transcript.segments {
            out.append(NSAttributedString(string: Timecode.hms(seg.start) + "\t", attributes: [
                .font: tsFont, .foregroundColor: NSColor.darkGray, .paragraphStyle: bodyStyle
            ]))
            out.append(NSAttributedString(string: seg.text + "\n", attributes: [
                .font: bodyFont, .foregroundColor: NSColor.black, .paragraphStyle: bodyStyle
            ]))
        }

        let discStyle = NSMutableParagraphStyle()
        discStyle.paragraphSpacingBefore = 16
        let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 9), toHaveTrait: .italicFontMask)
        out.append(NSAttributedString(string: "\n" + Disclaimer.long, attributes: [
            .font: italic,
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: discStyle
        ]))

        return out
    }
}
