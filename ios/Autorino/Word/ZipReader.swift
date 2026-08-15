import Foundation

/// Minimal ZIP archive reader — the inverse of `ZipWriter`, just enough to
/// pull a single named part (`word/document.xml`) out of an uploaded
/// `.docx`. Reads the central directory rather than scanning local headers
/// one at a time, so it doesn't care whether entries are stored or
/// deflated by whatever produced the file — real-world `.docx` files
/// (Word, Pages, Google Docs) all deflate, unlike `ZipWriter`'s own
/// stored-only output, so this needs `Compression`'s zlib deflate reader
/// to actually open them.
enum ZipReader {
    enum ZipError: Error { case notAZip, entryNotFound, corruptEntry }

    /// Returns the uncompressed bytes of `path` inside the ZIP `data`, or
    /// throws if the archive is malformed or doesn't contain that part.
    static func extract(path: String, from data: Data) throws -> Data {
        guard let eocdRange = findEndOfCentralDirectory(in: data) else { throw ZipError.notAZip }
        let eocd = data.subdata(in: eocdRange)
        let centralDirOffset = Int(eocd.readUInt32(at: 16))
        let centralDirSize = Int(eocd.readUInt32(at: 12))
        guard centralDirOffset + centralDirSize <= data.count else { throw ZipError.notAZip }

        var cursor = centralDirOffset
        let centralDirEnd = centralDirOffset + centralDirSize
        while cursor + 46 <= centralDirEnd {
            guard data.readUInt32(at: cursor) == 0x02014b50 else { break }
            let method = data.readUInt16(at: cursor + 10)
            let compressedSize = Int(data.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let localHeaderOffset = Int(data.readUInt32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw ZipError.corruptEntry }
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) ?? ""

            if name == path {
                return try readEntry(
                    from: data,
                    localHeaderOffset: localHeaderOffset,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                )
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        throw ZipError.entryNotFound
    }

    private static func readEntry(from data: Data, localHeaderOffset: Int, method: UInt16, compressedSize: Int, uncompressedSize: Int) throws -> Data {
        guard localHeaderOffset + 30 <= data.count, data.readUInt32(at: localHeaderOffset) == 0x04034b50 else {
            throw ZipError.corruptEntry
        }
        let nameLength = Int(data.readUInt16(at: localHeaderOffset + 26))
        let extraLength = Int(data.readUInt16(at: localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + nameLength + extraLength
        guard dataStart + compressedSize <= data.count else { throw ZipError.corruptEntry }
        let compressed = data.subdata(in: dataStart..<(dataStart + compressedSize))

        switch method {
        case 0: // stored
            return compressed
        case 8: // deflate
            return try Inflate.decompress(compressed, expectedSize: uncompressedSize)
        default:
            throw ZipError.corruptEntry
        }
    }

    /// Scans backward for the end-of-central-directory signature. The EOCD
    /// is a fixed 22 bytes plus an optional comment (max 65535 bytes), so
    /// this only needs to search the tail of the file.
    private static func findEndOfCentralDirectory(in data: Data) -> Range<Data.Index>? {
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let searchStart = max(0, data.count - 22 - 65535)
        var i = data.count - 22
        while i >= searchStart {
            if data[data.startIndex + i] == signature[0],
               data[data.startIndex + i + 1] == signature[1],
               data[data.startIndex + i + 2] == signature[2],
               data[data.startIndex + i + 3] == signature[3] {
                return (data.startIndex + i)..<data.endIndex
            }
            i -= 1
        }
        return nil
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | (UInt16(self[start + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start])
            | (UInt32(self[start + 1]) << 8)
            | (UInt32(self[start + 2]) << 16)
            | (UInt32(self[start + 3]) << 24)
    }
}
