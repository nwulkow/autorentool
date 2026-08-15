import Foundation

/// Minimal ZIP archive writer — just enough to produce a valid `.docx`
/// container (a `.docx` is a ZIP of XML parts). No third-party dependency:
/// entries are written **stored** (uncompressed), which is a fully valid
/// ZIP entry method and keeps this file self-contained — a `.docx` is a
/// handful of small XML files, so skipping deflate costs nothing that
/// matters and avoids pulling in `Compression`/zlib framework linkage for
/// what would be a few KB of savings.
///
/// This is intentionally tiny: no directories, no zip64, no encryption —
/// only what `DocxExporter` needs to produce a package Word/Pages/
/// `NSAttributedString(.docx)` can all read back.
struct ZipWriter {
    private struct Entry {
        let path: String
        let data: Data
        let crc32: UInt32
        let offset: UInt32
    }

    private var body = Data()
    private var entries: [Entry] = []

    mutating func addFile(path: String, data: Data) {
        let crc = Self.crc32(data)
        let offset = UInt32(body.count)
        let nameData = Data(path.utf8)

        // Local file header
        var local = Data()
        local.append(uint32: 0x04034b50)       // local file header signature
        local.append(uint16: 20)                // version needed
        local.append(uint16: 0)                 // flags
        local.append(uint16: 0)                 // method: 0 = stored
        local.append(uint16: 0)                 // mod time
        local.append(uint16: 0)                 // mod date
        local.append(uint32: crc)
        local.append(uint32: UInt32(data.count)) // compressed size == uncompressed (stored)
        local.append(uint32: UInt32(data.count))
        local.append(uint16: UInt16(nameData.count))
        local.append(uint16: 0)                 // extra field length
        local.append(nameData)
        local.append(data)

        body.append(local)
        entries.append(Entry(path: path, data: data, crc32: crc, offset: offset))
    }

    /// Finalizes the archive: local entries + a central directory + the
    /// end-of-central-directory record.
    func finalize() -> Data {
        var central = Data()
        for entry in entries {
            let nameData = Data(entry.path.utf8)
            central.append(uint32: 0x02014b50)   // central directory header signature
            central.append(uint16: 20)            // version made by
            central.append(uint16: 20)            // version needed
            central.append(uint16: 0)             // flags
            central.append(uint16: 0)             // method: stored
            central.append(uint16: 0)             // mod time
            central.append(uint16: 0)             // mod date
            central.append(uint32: entry.crc32)
            central.append(uint32: UInt32(entry.data.count))
            central.append(uint32: UInt32(entry.data.count))
            central.append(uint16: UInt16(nameData.count))
            central.append(uint16: 0)             // extra field length
            central.append(uint16: 0)             // comment length
            central.append(uint16: 0)             // disk number start
            central.append(uint16: 0)             // internal attributes
            central.append(uint32: 0)             // external attributes
            central.append(uint32: entry.offset)
            central.append(nameData)
        }

        var end = Data()
        end.append(uint32: 0x06054b50)            // end of central directory signature
        end.append(uint16: 0)                      // disk number
        end.append(uint16: 0)                      // disk with central directory
        end.append(uint16: UInt16(entries.count))  // entries on this disk
        end.append(uint16: UInt16(entries.count))  // total entries
        end.append(uint32: UInt32(central.count))  // central directory size
        end.append(uint32: UInt32(body.count))     // central directory offset
        end.append(uint16: 0)                      // comment length

        var archive = Data()
        archive.append(body)
        archive.append(central)
        archive.append(end)
        return archive
    }

    /// Standard ZIP CRC-32 (polynomial 0xEDB88320), computed with a
    /// generated 256-entry table — no `zlib` import needed for this alone.
    private static let crcTable: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
