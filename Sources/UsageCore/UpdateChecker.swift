import CryptoKit
import Foundation

public struct AppUpdateInfo: Sendable, Equatable {
    public let version: String
    public let tagName: String
    public let releaseURL: URL
    public let zipURL: URL?
    public let zipFileName: String?
    public let checksumsURL: URL?
    public let releaseNotes: String
    public let publishedAt: String?

    public init(
        version: String,
        tagName: String,
        releaseURL: URL,
        zipURL: URL? = nil,
        zipFileName: String? = nil,
        checksumsURL: URL? = nil,
        releaseNotes: String = "",
        publishedAt: String? = nil
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.zipURL = zipURL
        self.zipFileName = zipFileName
        self.checksumsURL = checksumsURL
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate(current: String)
    case updateAvailable(AppUpdateInfo)
    case failed(String)
}

public enum AppVersionComparator {
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        if let dash = s.firstIndex(of: "-") {
            s = String(s[..<dash])
        }
        return s
    }

    public static func components(of raw: String) -> [Int] {
        normalize(raw)
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    public static func isNewer(_ remote: String, than current: String) -> Bool {
        let r = components(of: remote)
        let c = components(of: current)
        let count = max(r.count, c.count)
        guard count > 0 else { return false }
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv {
                return rv > cv
            }
        }
        return false
    }
}

public struct UpdateChecker: Sendable {
    private struct GitHubReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }

        let tagName: String
        let htmlUrl: String
        let body: String?
        let publishedAt: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body
            case publishedAt = "published_at"
            case draft
            case prerelease
            case assets
        }
    }

    public let latestReleaseAPIURL: URL

    public init(
        latestReleaseAPIURL: URL = URL(string: "https://api.github.com/repos/cassianpan/antigravity-usage-monitor/releases/latest")!
    ) {
        self.latestReleaseAPIURL = latestReleaseAPIURL
    }

    public static func decodeGitHubRelease(_ data: Data, currentVersion: String) throws -> UpdateCheckResult {
        let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        let localVersion = AppVersionComparator.normalize(currentVersion)
        if release.draft == true || release.prerelease == true {
            return .upToDate(current: localVersion)
        }
        let remoteVersion = AppVersionComparator.normalize(release.tagName)
        guard AppVersionComparator.isNewer(remoteVersion, than: localVersion),
              let pageURL = URL(string: release.htmlUrl) else {
            return .upToDate(current: localVersion)
        }

        let assets = release.assets ?? []
        let zipAsset = assets.first(where: { $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("macos") })
            ?? assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
        let checksumAsset = assets.first(where: { $0.name == "SHA256SUMS.txt" })
            ?? zipAsset.flatMap { z in assets.first(where: { $0.name == z.name + ".sha256" }) }

        let info = AppUpdateInfo(
            version: remoteVersion,
            tagName: release.tagName,
            releaseURL: pageURL,
            zipURL: zipAsset.flatMap { URL(string: $0.browserDownloadUrl) },
            zipFileName: zipAsset?.name,
            checksumsURL: checksumAsset.flatMap { URL(string: $0.browserDownloadUrl) },
            releaseNotes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            publishedAt: release.publishedAt
        )
        return .updateAvailable(info)
    }

    public func checkLatestRelease(currentVersion: String) async -> UpdateCheckResult {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AntigravityUsageMonitor/\(AppVersionComparator.normalize(currentVersion))", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Invalid response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed("HTTP \(http.statusCode)")
            }
            return try Self.decodeGitHubRelease(data, currentVersion: currentVersion)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public static func parseSHA256(from checksumText: String, matchingFileName: String) -> String? {
        let target = matchingFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        for rawLine in checksumText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let hash = parts.first, hash.count == 64 else { continue }
            if parts.count == 1 {
                return String(hash).lowercased()
            }
            let filePart = parts.dropFirst().joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            if filePart == target || filePart.hasSuffix("/" + target) {
                return String(hash).lowercased()
            }
        }
        return nil
    }

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func verifySHA256(data: Data, expectedHex: String) -> Bool {
        sha256Hex(of: data) == expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func fetchExpectedSHA256(from checksumsURL: URL, matchingFileName: String) async throws -> String? {
        var request = URLRequest(url: checksumsURL)
        request.timeoutInterval = 15
        request.setValue("AntigravityUsageMonitor", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.parseSHA256(from: text, matchingFileName: matchingFileName)
    }

    public func downloadData(
        from url: URL,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = UpdateDownloadDelegate(onProgress: onProgress, continuation: continuation)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            request.setValue("AntigravityUsageMonitor", forHTTPHeaderField: "User-Agent")
            delegate.session = session
            session.downloadTask(with: request).resume()
        }
    }
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let onProgress: (@MainActor @Sendable (Double) -> Void)?
    private let continuation: CheckedContinuation<Data, Error>
    var session: URLSession?

    init(
        onProgress: (@MainActor @Sendable (Double) -> Void)?,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let onProgress else { return }
        let fraction = max(0, min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        Task { @MainActor in
            onProgress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let data = try Data(contentsOf: location)
            guard !data.isEmpty else {
                finish(.failure(URLError(.badServerResponse)))
                return
            }
            finish(.success(data))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let isFirst = !finished
        if isFirst { finished = true }
        lock.unlock()
        guard isFirst else { return }
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}
