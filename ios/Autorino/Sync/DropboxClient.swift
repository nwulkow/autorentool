import Foundation

/// Thin `URLSession` wrapper over the handful of Dropbox v2 REST endpoints
/// this app needs. Deliberately not the official Dropbox SDK — a handful
/// of REST calls doesn't justify a dependency, matching this codebase's
/// existing "no framework beyond what's needed" style.
actor DropboxClient {
    private let auth: DropboxAuthService

    init(auth: DropboxAuthService) {
        self.auth = auth
    }

    // MARK: - Listing

    func listFolder(path: String = "") async throws -> ListFolderResult {
        var request = try await authorizedRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "recursive": false,
            "include_deleted": true,
        ])
        let data = try await send(request)
        return try JSONDecoder().decode(ListFolderResult.self, from: data)
    }

    func listFolderContinue(cursor: String) async throws -> ListFolderResult {
        var request = try await authorizedRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": cursor])
        let data = try await send(request)
        return try JSONDecoder().decode(ListFolderResult.self, from: data)
    }

    // MARK: - Content

    enum UploadMode {
        case add
        case overwrite
        case update(rev: String)

        var jsonValue: Any {
            switch self {
            case .add: return [".tag": "add"]
            case .overwrite: return [".tag": "overwrite"]
            case .update(let rev): return [".tag": "update", "update": rev]
            }
        }
    }

    @discardableResult
    func upload(path: String, data fileData: Data, mode: UploadMode) async throws -> DropboxEntry {
        var request = try await authorizedRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let arg: [String: Any] = [
            "path": path,
            "mode": mode.jsonValue,
            "autorename": false,
            "mute": true,
            "strict_conflict": false,
        ]
        request.setValue(try Self.asciiEscapedJSON(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = fileData
        let data = try await send(request)
        return try JSONDecoder().decode(DropboxEntry.self, from: data)
    }

    func download(path: String) async throws -> (data: Data, entry: DropboxEntry) {
        var request = try await authorizedRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        request.httpMethod = "POST"
        request.setValue(try Self.asciiEscapedJSON(["path": path]), forHTTPHeaderField: "Dropbox-API-Arg")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        guard let http = response as? HTTPURLResponse,
              let resultHeader = http.value(forHTTPHeaderField: "Dropbox-API-Result"),
              let resultData = resultHeader.data(using: .utf8) else {
            throw DropboxAPIError.malformedResponse
        }
        let entry = try JSONDecoder().decode(DropboxEntry.self, from: resultData)
        return (data, entry)
    }

    func delete(path: String) async throws {
        var request = try await authorizedRequest(url: URL(string: "https://api.dropboxapi.com/2/files/delete_v2")!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": path])
        _ = try await send(request)
    }

    // MARK: - Plumbing

    private func authorizedRequest(url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let token = try await auth.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        return data
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DropboxAPIError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }
    }

    /// Dropbox requires the `Dropbox-API-Arg` header to be ASCII — any
    /// character outside 0x00-0x7F must be `\uXXXX`-escaped (relevant here
    /// because book titles routinely contain German umlauts).
    private static func asciiEscapedJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DropboxAPIError.malformedResponse
        }
        var out = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            if scalar.value > 127 {
                out.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}

struct DropboxEntry: Codable, Hashable {
    let tag: String
    let name: String
    let pathLower: String?
    let id: String?
    let rev: String?
    let contentHash: String?
    let serverModified: String?

    enum CodingKeys: String, CodingKey {
        case tag = ".tag"
        case name
        case pathLower = "path_lower"
        case id, rev
        case contentHash = "content_hash"
        case serverModified = "server_modified"
    }

    var isDeleted: Bool { tag == "deleted" }
    var isFile: Bool { tag == "file" }
}

struct ListFolderResult: Codable {
    let entries: [DropboxEntry]
    let cursor: String
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case entries, cursor
        case hasMore = "has_more"
    }
}

enum DropboxAPIError: LocalizedError {
    case requestFailed(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed(let code, let body): return "Dropbox API error \(code): \(body)"
        case .malformedResponse: return "Unexpected Dropbox response shape."
        }
    }
}
