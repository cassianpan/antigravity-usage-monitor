import Foundation

public struct AppUpdateInfo: Sendable, Equatable {
    public let version: String
    public let tagName: String
    public let releaseURL: URL
    public let publishedAt: String?

    public init(version: String, tagName: String, releaseURL: URL, publishedAt: String? = nil) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
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
        let tagName: String
        let htmlUrl: String
        let publishedAt: String?
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case publishedAt = "published_at"
            case draft
            case prerelease
        }
    }

    public let latestReleaseAPIURL: URL

    public init(
        latestReleaseAPIURL: URL = URL(string: "https://api.github.com/repos/cassianpan/antigravity-usage-monitor/releases/latest")!
    ) {
        self.latestReleaseAPIURL = latestReleaseAPIURL
    }

    public func checkLatestRelease(currentVersion: String) async -> UpdateCheckResult {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.timeoutInterval = 10
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
            let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
            if release.draft == true || release.prerelease == true {
                return .upToDate(current: AppVersionComparator.normalize(currentVersion))
            }
            let remoteVersion = AppVersionComparator.normalize(release.tagName)
            let localVersion = AppVersionComparator.normalize(currentVersion)
            if AppVersionComparator.isNewer(remoteVersion, than: localVersion),
               let url = URL(string: release.htmlUrl) {
                return .updateAvailable(
                    AppUpdateInfo(
                        version: remoteVersion,
                        tagName: release.tagName,
                        releaseURL: url,
                        publishedAt: release.publishedAt
                    )
                )
            }
            return .upToDate(current: localVersion)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
