import SwiftUI
import UniformTypeIdentifiers

/// Thin `FileDocument` wrapper so `DocxExporter`'s output `Data` can be
/// handed to SwiftUI's native `.fileExporter` — the iOS replacement for
/// app.js's `downloadBlob` (app.js:1861-1866), which built an `<a
/// download>` link. `.fileExporter` opens the system document picker so
/// the user chooses where the `.docx` lands (Files app, iCloud Drive,
/// another app via "Save to..."), the closest iOS equivalent to a browser
/// download.
struct DocxFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [UTType(filenameExtension: "docx") ?? .data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
