import Foundation
import os

/// Minimal Google Drive v3 REST client. With the drive.file scope it can only see
/// files and folders this app created — so it always creates its own /Coach/health.
@MainActor
final class DriveClient {
    enum DriveError: LocalizedError {
        case http(Int, String)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return "Drive error \(code): \(msg)"
            case .badResponse: return "Unexpected response from Drive."
            }
        }
    }

    enum UploadOutcome: Sendable, Equatable { case created, updated }

    struct DriveFile: Decodable { let id: String; let name: String }
    private struct IDOnly: Decodable { let id: String }
    private struct FileList: Decodable { let files: [DriveFile]; let nextPageToken: String? }
    private struct GoogleErrorBody: Decodable {
        struct Inner: Decodable { let message: String? }
        let error: Inner?
    }

    static let folderMime = "application/vnd.google-apps.folder"
    private static let api = "https://www.googleapis.com/drive/v3/files"
    private static let upload = "https://www.googleapis.com/upload/drive/v3/files"

    private let token: () async throws -> String
    private let session: URLSession
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "drive")
    private var folderCache: [String: String] = [:]   // path → folder ID, in memory only

    init(session: URLSession = .shared, token: @escaping () async throws -> String) {
        self.session = session
        self.token = token
    }

    // MARK: - Public

    /// Creates or overwrites `<folderPath>/<name>` with `data`. Idempotent: re-exporting a day replaces its file.
    func upsertJSON(named name: String, data: Data, folderPath: [String]) async throws -> UploadOutcome {
        let folderID = try await ensureFolderPath(folderPath)
        let existing = try await find(name: name, parent: folderID, mimeType: nil)?.id
        return try await upsertJSON(named: name, data: data, folderID: folderID, existingID: existing)
    }

    /// Same, when the caller already knows the folder and whether the file exists (from `listFiles`).
    func upsertJSON(named name: String, data: Data, folderID: String, existingID: String?) async throws -> UploadOutcome {
        if let existingID {
            var req = URLRequest(url: URL(string: "\(Self.upload)/\(existingID)?uploadType=media&fields=id")!)
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            _ = try await send(req)
            return .updated
        } else {
            let boundary = "coachbridge-\(UUID().uuidString)"
            let metadata = try JSONSerialization.data(withJSONObject: [
                "name": name, "parents": [folderID], "mimeType": "application/json",
            ])
            var req = URLRequest(url: URL(string: "\(Self.upload)?uploadType=multipart&fields=id")!)
            req.httpMethod = "POST"
            req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.multipartBody(metadata: metadata, media: data, boundary: boundary)
            _ = try await send(req)
            return .created
        }
    }

    /// Name → file ID for every (non-trashed) file in a folder. Oldest first, so if a
    /// duplicate name ever exists the first-created copy wins, matching `find`.
    func listFiles(inFolder folderID: String) async throws -> [String: String] {
        var result: [String: String] = [:]
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: Self.api)!
            var items = [
                URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed = false"),
                URLQueryItem(name: "spaces", value: "drive"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name)"),
                URLQueryItem(name: "orderBy", value: "createdTime"),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let data = try await send(URLRequest(url: comps.url!))
            let page = try JSONDecoder().decode(FileList.self, from: data)
            for f in page.files where result[f.name] == nil { result[f.name] = f.id }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return result
    }

    // MARK: - Folders

    func ensureFolderPath(_ path: [String]) async throws -> String {
        let key = path.joined(separator: "/")
        if let cached = folderCache[key] { return cached }
        var parent = "root"
        for name in path {
            if let existing = try await find(name: name, parent: parent, mimeType: Self.folderMime) {
                parent = existing.id
            } else {
                parent = try await createFolder(name: name, parent: parent)
                log.info("Created a Drive folder")
            }
        }
        folderCache[key] = parent
        return parent
    }

    private func createFolder(name: String, parent: String) async throws -> String {
        var req = URLRequest(url: URL(string: "\(Self.api)?fields=id")!)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "mimeType": Self.folderMime, "parents": [parent],
        ])
        let data = try await send(req)
        return try JSONDecoder().decode(IDOnly.self, from: data).id
    }

    private func find(name: String, parent: String, mimeType: String?) async throws -> DriveFile? {
        var q = "name = '\(Self.escape(name))' and '\(parent)' in parents and trashed = false"
        if let mimeType { q += " and mimeType = '\(mimeType)'" }
        var comps = URLComponents(string: Self.api)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "orderBy", value: "createdTime"),
            URLQueryItem(name: "pageSize", value: "10"),
        ]
        // URLComponents leaves "+" unescaped; Google would read it as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let data = try await send(URLRequest(url: comps.url!))
        return try JSONDecoder().decode(FileList.self, from: data).files.first
    }

    // MARK: - Transport

    private func send(_ request: URLRequest) async throws -> Data {
        var req = request
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DriveError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(GoogleErrorBody.self, from: data))?.error?.message ?? "no details"
            log.error("Drive request failed with HTTP \(http.statusCode, privacy: .public)")
            throw DriveError.http(http.statusCode, message)
        }
        return data
    }

    // MARK: - Pure helpers (unit-tested)

    nonisolated static func multipartBody(metadata: Data, media: Data, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(media)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Escapes a value for use inside single quotes in a Drive query.
    nonisolated static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}
