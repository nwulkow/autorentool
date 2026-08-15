import Foundation
import Compression

/// Raw DEFLATE decompression for ZIP entries stored with method 8, via
/// Apple's first-party `Compression` framework (`COMPRESSION_ZLIB`'s raw
/// variant, no zlib header/trailer — matching what ZIP's deflate method
/// actually stores). This is a system framework, not a third-party
/// dependency — hand-rolling DEFLATE's Huffman/LZ77 decoder ourselves
/// would be a much larger and more error-prone undertaking than the
/// OOXML-writing `ZipWriter` sidesteps by staying "stored"-only; reading
/// arbitrary real-world `.docx` files (Word/Pages/Google Docs all
/// deflate) has no such shortcut available.
enum Inflate {
    enum InflateError: Error { case failed }

    static func decompress(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let resultSize = output.withUnsafeMutableBytes { outputPtr -> Int in
            compressed.withUnsafeBytes { inputPtr -> Int in
                guard let outputBase = outputPtr.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = inputPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outputBase, expectedSize,
                    inputBase, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard resultSize == expectedSize else { throw InflateError.failed }
        return output
    }
}
