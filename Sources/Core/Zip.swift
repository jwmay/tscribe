import Foundation

/// Standard CRC-32 (polynomial 0xEDB88320), needed for ZIP entries.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

/// Minimal STORED (uncompressed) ZIP writer — enough to build a valid .docx
/// (OPC package). No external dependencies. Entry names are written verbatim,
/// so parts land at the archive root as OOXML requires.
struct ZipWriter {
    private struct Entry { let name: String; let size: Int; let crc: UInt32; let offset: Int }
    private var entries: [Entry] = []
    private var output = Data()

    mutating func add(_ name: String, _ data: Data) {
        let crc = CRC32.checksum(data)
        let offset = output.count
        let nameBytes = Data(name.utf8)

        output.appendLE32(0x04034b50)               // local file header signature
        output.appendLE16(20)                        // version needed
        output.appendLE16(0)                         // flags
        output.appendLE16(0)                         // method: stored
        output.appendLE16(0)                         // mod time
        output.appendLE16(0x21)                      // mod date (1980-01-01)
        output.appendLE32(crc)
        output.appendLE32(UInt32(data.count))        // compressed size
        output.appendLE32(UInt32(data.count))        // uncompressed size
        output.appendLE16(UInt16(nameBytes.count))
        output.appendLE16(0)                         // extra length
        output.append(nameBytes)
        output.append(data)

        entries.append(Entry(name: name, size: data.count, crc: crc, offset: offset))
    }

    mutating func finalize() -> Data {
        let cdStart = output.count
        var cd = Data()
        for e in entries {
            let nameBytes = Data(e.name.utf8)
            cd.appendLE32(0x02014b50)                // central directory signature
            cd.appendLE16(20)                        // version made by
            cd.appendLE16(20)                        // version needed
            cd.appendLE16(0)                         // flags
            cd.appendLE16(0)                         // method
            cd.appendLE16(0)                         // time
            cd.appendLE16(0x21)                      // date
            cd.appendLE32(e.crc)
            cd.appendLE32(UInt32(e.size))
            cd.appendLE32(UInt32(e.size))
            cd.appendLE16(UInt16(nameBytes.count))
            cd.appendLE16(0)                         // extra
            cd.appendLE16(0)                         // comment
            cd.appendLE16(0)                         // disk number
            cd.appendLE16(0)                         // internal attrs
            cd.appendLE32(0)                         // external attrs
            cd.appendLE32(UInt32(e.offset))
            cd.append(nameBytes)
        }
        output.append(cd)

        output.appendLE32(0x06054b50)                // end of central directory
        output.appendLE16(0)                         // disk
        output.appendLE16(0)                         // disk with cd
        output.appendLE16(UInt16(entries.count))
        output.appendLE16(UInt16(entries.count))
        output.appendLE32(UInt32(cd.count))
        output.appendLE32(UInt32(cdStart))
        output.appendLE16(0)                         // comment length
        return output
    }
}

private extension Data {
    mutating func appendLE16(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE32(_ v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}
