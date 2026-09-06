import Foundation

protocol AppUpdateSourceProviding: Sendable {
    func fetchLatest() async throws -> AppUpdateRelease
}

struct AppUpdateGitHubReleaseProvider: AppUpdateSourceProviding {
    let endpoint: URL
    let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func fetchLatest() async throws -> AppUpdateRelease {
        try AppUpdateURLPolicy.validateHTTPS(endpoint)
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let data: Data
        do { data = try await AppUpdateHTTPClient.data(for: request, session: session) }
        catch AppUpdateError.invalidHTTPStatus(404) { throw AppUpdateError.noPublishedRelease }
        let payload: GitHubReleasePayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(GitHubReleasePayload.self, from: data)
        }
        catch { throw AppUpdateError.malformedManifest(error.localizedDescription) }
        guard !payload.draft, !payload.prerelease else { throw AppUpdateError.noPublishedRelease }
        guard let asset = payload.assets.first(where: { AppUpdateAssetSelector.select(name: $0.name, url: $0.browserDownloadURL) }) else {
            throw AppUpdateError.unsupportedAsset
        }
        try AppUpdateURLPolicy.validateHTTPS(asset.browserDownloadURL)
        return AppUpdateRelease(version: payload.tagName, title: payload.name ?? payload.tagName,
                                notes: payload.body ?? "", publishedAt: payload.publishedAt,
                                downloadURL: asset.browserDownloadURL, assetName: asset.name,
                                source: .githubRelease)
    }
}

struct AppUpdatePagesManifestProvider: AppUpdateSourceProviding {
    let endpoint: URL
    let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func fetchLatest() async throws -> AppUpdateRelease {
        try AppUpdateURLPolicy.validateHTTPS(endpoint)
        let data = try await AppUpdateHTTPClient.data(for: URLRequest(url: endpoint), session: session)
        let manifest: AppUpdateManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(AppUpdateManifest.self, from: data)
        }
        catch { throw AppUpdateError.malformedManifest(error.localizedDescription) }
        guard !manifest.version.isEmpty else { throw AppUpdateError.malformedManifest("缺少 version。") }
        guard AppUpdateAssetSelector.select(name: manifest.assetName, url: manifest.downloadURL) else {
            throw AppUpdateError.unsupportedAsset
        }
        try AppUpdateURLPolicy.validateHTTPS(manifest.downloadURL)
        return AppUpdateRelease(version: manifest.version, title: manifest.title ?? manifest.version,
                                notes: manifest.notes ?? "", publishedAt: manifest.publishedAt,
                                downloadURL: manifest.downloadURL, assetName: manifest.assetName,
                                source: .pagesManifest)
    }
}

private struct GitHubReleasePayload: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey { case tagName = "tag_name", name, body, draft, prerelease, publishedAt = "published_at", assets }
}

private struct GitHubAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
}

struct AppUpdateManifest: Codable, Sendable, Equatable {
    let version: String
    let title: String?
    let notes: String?
    let publishedAt: Date?
    let downloadURL: URL
    let assetName: String

    enum CodingKeys: String, CodingKey { case version, title, notes, publishedAt = "published_at", downloadURL = "download_url", assetName = "asset_name" }
}
