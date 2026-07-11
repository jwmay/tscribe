import Foundation

/// Standard, machine-generated disclaimer text for legal/evidentiary use.
enum Disclaimer {
    static let short = "Draft transcript — not a certified record. Verify against the original recording."
    static let long = """
    This is a machine-generated draft transcript produced entirely on-device by Tscribe. \
    It is not a certified or verbatim record and may contain errors — especially for unclear \
    audio, crosstalk, overlapping speakers, or proper names. Always verify against the original \
    recording before relying on it.
    """
}

/// Timecode formatting helpers.
enum Timecode {
    static func hms(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    /// Wall-clock formatting: wraps at 24 h (a recording that crosses midnight
    /// rolls over from 23:59:59 to 00:00:00, like the on-screen clock it mirrors).
    static func wall(_ t: TimeInterval) -> String {
        var s = Int(t) % 86_400
        if s < 0 { s += 86_400 }
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    static func srt(_ t: TimeInterval) -> String {
        let ms = max(0, Int((t * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }
    static func vtt(_ t: TimeInterval) -> String {
        let ms = max(0, Int((t * 1000).rounded()))
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }
}

/// Turns a Transcript into exportable file formats.
enum Exporter {
    static func plainText(_ t: Transcript, timestamps: Bool) -> String {
        var lines: [String] = []
        var last: String? = nil
        for seg in t.segments {
            // Dialogue-style: a "Name:" line whenever the speaker changes (diarized only).
            if let key = seg.speaker, key != last {
                if !lines.isEmpty { lines.append("") }
                lines.append("\(t.displayName(forSpeaker: key) ?? "Speaker \(key)"):")
            }
            last = seg.speaker
            let ts = timestamps ? "[\(t.timecode(seg.start))] " : ""
            lines.append("\(ts)\(seg.text)")
        }
        return lines.joined(separator: "\n") + "\n\n" + Disclaimer.long + "\n"
    }

    static func srt(_ t: Transcript) -> String {
        t.segments.enumerated().map { i, seg in
            let prefix = t.displayName(forSpeaker: seg.speaker).map { "\($0): " } ?? ""
            return "\(i + 1)\n\(Timecode.srt(seg.start)) --> \(Timecode.srt(seg.end))\n\(prefix)\(seg.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ t: Transcript) -> String {
        "WEBVTT\n\n" + t.segments.map { seg in
            // Standard WebVTT voice tag; strip any ">" so a name can't break the cue.
            let cue: String
            if let name = t.displayName(forSpeaker: seg.speaker) {
                cue = "<v \(name.replacingOccurrences(of: ">", with: ""))>\(seg.text)"
            } else {
                cue = seg.text
            }
            return "\(Timecode.vtt(seg.start)) --> \(Timecode.vtt(seg.end))\n\(cue)\n"
        }.joined(separator: "\n")
    }

    /// Minimal RTF (opens cleanly in Word/Pages) with bold timestamps.
    static func rtf(_ t: Transcript) -> Data {
        func esc(_ s: String) -> String {
            var r = ""
            for u in s.unicodeScalars {
                switch u {
                case "\\": r += "\\\\"
                case "{": r += "\\{"
                case "}": r += "\\}"
                default:
                    if u.value > 127 { r += "\\u\(Int(u.value)) " } else { r.unicodeScalars.append(u) }
                }
            }
            return r
        }
        var body = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24\n"
        body += "{\\b\\fs32 Transcript}\\par\\par\n"
        var last: String? = nil
        for seg in t.segments {
            if let name = t.displayName(forSpeaker: seg.speaker), seg.speaker != last {
                if last != nil { body += "\\par" }   // gap before a new speaker turn
                body += "{\\b \(esc(name))}\\par\n"
            }
            last = seg.speaker
            body += "{\\b \(t.timecode(seg.start))}\\tab \(esc(seg.text))\\par\n"
        }
        body += "\\par{\\i \(esc(Disclaimer.long))}\\par\n}"
        return Data(body.utf8)
    }

    /// A real Word .docx (OPC package): bold timestamps + text, italic disclaimer.
    static func docx(_ t: Transcript) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .replacingOccurrences(of: "\"", with: "&quot;")
        }
        // A run of text; multi-line text becomes <w:br/> breaks.
        func run(_ text: String, bold: Bool = false, italic: Bool = false, sizeHalfPt: Int? = nil) -> String {
            var props = ""
            if bold { props += "<w:b/>" }
            if italic { props += "<w:i/>" }
            if let sz = sizeHalfPt { props += "<w:sz w:val=\"\(sz)\"/><w:szCs w:val=\"\(sz)\"/>" }
            let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
            let content = esc(text)
                .components(separatedBy: "\n")
                .enumerated()
                .map { (i, line) in (i == 0 ? "" : "<w:br/>") + "<w:t xml:space=\"preserve\">\(line)</w:t>" }
                .joined()
            return "<w:r>\(rPr)\(content)</w:r>"
        }
        func para(_ runs: String, pPr: String = "") -> String { "<w:p>\(pPr)\(runs)</w:p>" }

        // Hanging indent (1") + matching tab stop so wrapped lines align under the
        // text, not back under the timestamp.
        let segPr = "<w:pPr>"
            + "<w:tabs><w:tab w:val=\"left\" w:pos=\"1440\"/></w:tabs>"
            + "<w:ind w:left=\"1440\" w:hanging=\"1440\"/>"
            + "<w:spacing w:after=\"120\"/>"
            + "</w:pPr>"

        // Bold speaker heading before each new turn (diarized only).
        let speakerPr = "<w:pPr><w:spacing w:before=\"120\" w:after=\"40\"/></w:pPr>"

        var body = para(run("Transcript", bold: true, sizeHalfPt: 32))
        var last: String? = nil
        for seg in t.segments {
            if let name = t.displayName(forSpeaker: seg.speaker), seg.speaker != last {
                body += para(run(name, bold: true), pPr: speakerPr)
            }
            last = seg.speaker
            body += para(run(t.timecode(seg.start), bold: true)
                         + "<w:r><w:tab/></w:r>"
                         + run(seg.text), pPr: segPr)
        }
        body += para("")
        body += para(run(Disclaimer.long, italic: true))

        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:body>\(body)<w:sectPr/></w:body></w:document>"

        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "</Types>"

        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
            + "</Relationships>"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(rels.utf8))
        zip.add("word/document.xml", Data(document.utf8))
        return zip.finalize()
    }
}
