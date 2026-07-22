import Foundation

actor BilibiliService {
    static let shared = BilibiliService()

    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private var wbiKeys: WBIKeys?
    private var deviceCookie: String?

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0 Safari/537.36"

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.cookieStorage = session.configuration.httpCookieStorage ?? .shared
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
            configuration.httpCookieStorage = .shared
            self.session = URLSession(configuration: configuration)
            self.cookieStorage = .shared
        }
    }

    func search(keyword: String, page: Int = 1) async throws -> [VideoSearchResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        try await bootstrapDeviceIfNeeded()
        let parameters = [
            "Search_key": trimmed,
            "keyword": trimmed,
            "page": String(page),
            "context": "",
            "duration": "0",
            "tids_2": "",
            "__refresh__": "true",
            "search_type": "video",
            "tids": "0",
            "highlight": "1",
        ]
        let url = apiURL(path: "/x/web-interface/search/type", parameters: parameters)
        let response: SearchResponse = try await request(url)
        try validate(response.code, response.message)

        return (response.data?.result ?? []).compactMap { item in
            guard !item.bvid.isEmpty else { return nil }
            return VideoSearchResult(
                bvid: item.bvid,
                title: item.title.removingHTML,
                creator: item.author,
                description: item.description.removingHTML,
                coverURL: Self.normalizedImageURL(item.pic),
                durationText: item.duration,
                playCountText: Self.compactCount(item.play),
                publishedAt: item.pubdate.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    func topRelatedVideo(for video: VideoSearchResult) async throws -> VideoSearchResult? {
        (try await relatedVideos(for: video)).first
    }

    func relatedVideos(for video: VideoSearchResult) async throws -> [VideoSearchResult] {
        try await bootstrapDeviceIfNeeded()
        let url = apiURL(
            path: "/x/web-interface/archive/related",
            parameters: [
                "bvid": video.bvid,
                "need_operation_card": "1",
                "web_rm_repeat": "1",
            ]
        )
        let response: RelatedVideosResponse = try await request(url, referer: video.webURL)
        try validate(response.code, response.message)
        var seenIDs = Set([video.id])
        return (response.data ?? []).compactMap { item in
            guard !item.bvid.isEmpty,
                seenIDs.insert(item.bvid).inserted
            else { return nil }
            return VideoSearchResult(
                bvid: item.bvid,
                title: (item.title ?? "Bilibili 视频").removingHTML,
                creator: item.owner?.name ?? "",
                description: (item.description ?? "").removingHTML,
                coverURL: item.picture.flatMap(Self.normalizedImageURL),
                durationText: Self.durationText(item.duration ?? 0),
                playCountText: Self.compactCount(item.statistics?.viewCount),
                publishedAt: item.publishedAt.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
            )
        }
    }

    func videoParts(for video: VideoSearchResult) async throws -> [VideoPart] {
        try await bootstrapDeviceIfNeeded()
        let pagesURL = apiURL(
            path: "/x/player/pagelist",
            parameters: ["bvid": video.bvid, "jsonp": "jsonp"]
        )
        let pagesResponse: PagesResponse = try await request(pagesURL, referer: video.webURL)
        try validate(pagesResponse.code, pagesResponse.message)
        let parts = (pagesResponse.data ?? []).map { page in
            VideoPart(
                cid: page.cid,
                number: page.page,
                title: page.part,
                duration: TimeInterval(page.duration)
            )
        }
        guard !parts.isEmpty else { throw BilibiliError.noPages }
        return parts
    }

    func resolveAudio(for video: VideoSearchResult) async throws -> AudioStream {
        guard let part = try await videoParts(for: video).first else {
            throw BilibiliError.noPages
        }
        return try await resolveAudio(for: video, part: part)
    }

    func resolveAudio(for video: VideoSearchResult, part: VideoPart) async throws -> AudioStream {
        try await bootstrapDeviceIfNeeded()

        let keys = try await loadWBIKeys()
        var playParameters = [
            "bvid": video.bvid,
            "cid": String(part.cid),
            "fnval": "4048",
            "fnver": "0",
            "fourk": "1",
            "otype": "json",
            "dm_img_list": "[]",
            "dm_img_str": Self.fingerprintToken(),
            "dm_cover_img_str": Self.fingerprintToken(),
            "dm_img_inter": #"{"ds":[],"wh":[3840,2160,0],"of":[30,0,0]}"#,
        ]
        if !hasLoginCookie {
            playParameters["try_look"] = "1"
        }
        let playURL = signedURL(
            path: "/x/player/wbi/playurl",
            parameters: playParameters,
            keys: keys
        )
        let playResponse: PlayURLResponse = try await request(playURL, referer: video.webURL)
        try validate(playResponse.code, playResponse.message)

        guard let audio = playResponse.data?.dash?.audio.max(by: { $0.bandwidth < $1.bandwidth }),
            let streamURL = audio.primaryURL
        else {
            throw BilibiliError.noAudio
        }

        return AudioStream(
            url: streamURL,
            duration: part.duration,
            pageTitle: part.title,
            representationID: audio.id,
            bandwidth: audio.bandwidth
        )
    }

    func playbackHeaders(for video: VideoSearchResult) -> [String: String] {
        [
            "User-Agent": Self.userAgent,
            "Referer": video.webURL?.absoluteString ?? "https://www.bilibili.com/",
        ]
    }

    func account() async throws -> BilibiliAccount? {
        try await bootstrapDeviceIfNeeded()
        let response: NavResponse = try await request(apiURL(path: "/x/web-interface/nav", parameters: [:]))
        guard response.data?.isLogin == true else { return nil }
        return BilibiliAccount(
            name: response.data?.userName ?? "Bilibili 用户",
            avatarURL: response.data?.avatar.flatMap(URL.init(string:))
        )
    }

    func beginQRCodeLogin() async throws -> QRCodeLoginSession {
        let url = passportURL(path: "/x/passport-login/web/qrcode/generate", parameters: [:])
        let response: QRCodeGenerateResponse = try await request(url)
        try validate(response.code, response.message)
        guard let data = response.data, let loginURL = URL(string: data.url) else {
            throw BilibiliError.invalidResponse
        }
        return QRCodeLoginSession(key: data.key, url: loginURL)
    }

    func pollQRCodeLogin(key: String) async throws -> QRCodeLoginStatus {
        let url = passportURL(
            path: "/x/passport-login/web/qrcode/poll",
            parameters: ["qrcode_key": key]
        )
        let response: QRCodePollResponse = try await request(url)
        try validate(response.code, response.message)
        guard let data = response.data else { throw BilibiliError.invalidResponse }
        switch data.code {
        case 0: return .confirmed
        case 86090: return .waitingForConfirmation
        case 86038: return .expired
        default: return .waitingForScan
        }
    }

    func logOutLocally() {
        guard let cookies = cookieStorage.cookies else { return }
        for cookie in cookies where cookie.domain.contains("bilibili.com") {
            cookieStorage.deleteCookie(cookie)
        }
        deviceCookie = nil
        wbiKeys = nil
    }

    private func bootstrapDeviceIfNeeded() async throws {
        guard deviceCookie == nil else { return }
        let url = apiURL(path: "/x/frontend/finger/spi", parameters: [:])
        let response: FingerprintResponse = try await request(url, includeCookie: false)
        guard response.code == 0, let data = response.data else { return }

        var cookies: [String] = []
        if !data.b3.isEmpty { cookies.append("buvid3=\(data.b3)") }
        if !data.b4.isEmpty { cookies.append("buvid4=\(data.b4)") }
        cookies.append("b_nut=\(Int(Date().timeIntervalSince1970))")
        deviceCookie = cookies.joined(separator: "; ")
        storeDeviceCookies(data)
    }

    private func loadWBIKeys() async throws -> WBIKeys {
        if let wbiKeys, Date().timeIntervalSince(wbiKeys.loadedAt) < 6 * 60 * 60 {
            return wbiKeys
        }

        let url = apiURL(path: "/x/web-interface/nav", parameters: [:])
        let response: NavResponse = try await request(url)
        guard let imageURL = response.data?.wbiImage.imageURL,
            let subURL = response.data?.wbiImage.subURL,
            let imageKey = WBISigner.key(from: imageURL),
            let subKey = WBISigner.key(from: subURL)
        else {
            throw BilibiliError.invalidResponse
        }

        let keys = WBIKeys(image: imageKey, sub: subKey, loadedAt: Date())
        wbiKeys = keys
        return keys
    }

    private func request<Response: Decodable & Sendable>(
        _ url: URL,
        referer: URL? = nil,
        includeCookie: Bool = true
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(referer?.absoluteString ?? "https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        if includeCookie, let cookie = cookieHeader(for: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw BilibiliError.invalidResponse
        }
        storeResponseCookies(from: http, for: url)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BilibiliError.invalidResponse
        }
    }

    private func signedURL(path: String, parameters: [String: String], keys: WBIKeys) -> URL {
        let query = WBISigner.signedQuery(
            parameters: parameters,
            imageKey: keys.image,
            subKey: keys.sub,
            timestamp: Int(Date().timeIntervalSince1970)
        )
        return URL(string: "https://api.bilibili.com\(path)?\(query)")!
    }

    private func apiURL(path: String, parameters: [String: String]) -> URL {
        url(host: "api.bilibili.com", path: path, parameters: parameters)
    }

    private func passportURL(path: String, parameters: [String: String]) -> URL {
        url(host: "passport.bilibili.com", path: path, parameters: parameters)
    }

    private func url(host: String, path: String, parameters: [String: String]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = parameters.keys.sorted().map {
            URLQueryItem(name: $0, value: parameters[$0])
        }
        return components.url!
    }

    private func cookieHeader(for url: URL) -> String? {
        var values: [String: String] = [:]
        for cookie in cookieStorage.cookies(for: url) ?? [] {
            values[cookie.name] = cookie.value
        }
        if let deviceCookie {
            for pair in deviceCookie.split(separator: ";") {
                let pieces = pair.split(separator: "=", maxSplits: 1)
                if pieces.count == 2, values[String(pieces[0]).trimmingCharacters(in: .whitespaces)] == nil {
                    values[String(pieces[0]).trimmingCharacters(in: .whitespaces)] = String(pieces[1])
                }
            }
        }
        guard !values.isEmpty else { return nil }
        return values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
    }

    private var hasLoginCookie: Bool {
        let url = URL(string: "https://api.bilibili.com/")!
        return (cookieStorage.cookies(for: url) ?? []).contains { $0.name == "SESSDATA" }
    }

    private func storeDeviceCookies(_ data: FingerprintData) {
        let values = ["buvid3": data.b3, "buvid4": data.b4]
        for (name, value) in values where !value.isEmpty {
            guard
                let cookie = HTTPCookie(properties: [
                    .domain: ".bilibili.com",
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                    .expires: Date().addingTimeInterval(365 * 24 * 60 * 60),
                ])
            else { continue }
            cookieStorage.setCookie(cookie)
        }
    }

    private func storeResponseCookies(from response: HTTPURLResponse, for url: URL) {
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { fields, entry in
            fields[String(describing: entry.key)] = String(describing: entry.value)
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url) {
            cookieStorage.setCookie(cookie)
        }
    }

    private static func fingerprintToken() -> String {
        Data((UUID().uuidString + UUID().uuidString).utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    private func validate(_ code: Int, _ message: String) throws {
        guard code == 0 else { throw BilibiliError.api(code: code, message: message) }
    }

    private static func normalizedImageURL(_ raw: String) -> URL? {
        if raw.hasPrefix("//") { return URL(string: "https:\(raw)") }
        if raw.hasPrefix("http://") {
            return URL(string: "https://\(raw.dropFirst("http://".count))")
        }
        return URL(string: raw)
    }

    private static func compactCount(_ count: Int?) -> String {
        guard let count else { return "--" }
        if count >= 100_000_000 { return String(format: "%.1f亿", Double(count) / 100_000_000) }
        if count >= 10_000 { return String(format: "%.1f万", Double(count) / 10_000) }
        return String(count)
    }

    private static func durationText(_ duration: Int) -> String {
        let seconds = max(0, duration)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct WBIKeys {
    let image: String
    let sub: String
    let loadedAt: Date
}

private protocol APIResponse {
    var code: Int { get }
    var message: String { get }
}

private struct FingerprintResponse: Decodable, Sendable, APIResponse {
    let code: Int
    let message: String
    let data: FingerprintData?
}

private struct FingerprintData: Decodable, Sendable {
    let b3: String
    let b4: String

    enum CodingKeys: String, CodingKey {
        case b3 = "b_3"
        case b4 = "b_4"
    }
}

private struct NavResponse: Decodable, Sendable, APIResponse {
    let code: Int
    let message: String
    let data: NavData?
}

private struct NavData: Decodable, Sendable {
    let wbiImage: WBIImage
    let isLogin: Bool?
    let userName: String?
    let avatar: String?

    enum CodingKeys: String, CodingKey {
        case wbiImage = "wbi_img"
        case isLogin
        case userName = "uname"
        case avatar = "face"
    }
}

private struct QRCodeGenerateResponse: Decodable, Sendable, APIResponse {
    let code: Int
    let message: String
    let data: QRCodeGenerateData?
}

private struct QRCodeGenerateData: Decodable, Sendable {
    let url: String
    let key: String

    enum CodingKeys: String, CodingKey {
        case url
        case key = "qrcode_key"
    }
}

private struct QRCodePollResponse: Decodable, Sendable, APIResponse {
    let code: Int
    let message: String
    let data: QRCodePollData?
}

private struct QRCodePollData: Decodable, Sendable {
    let code: Int
}

private struct WBIImage: Decodable, Sendable {
    let imageURL: String
    let subURL: String

    enum CodingKeys: String, CodingKey {
        case imageURL = "img_url"
        case subURL = "sub_url"
    }
}

private struct SearchResponse: Decodable, Sendable, APIResponse {
    let code: Int
    let message: String
    let data: SearchData?
}

private struct SearchData: Decodable, Sendable {
    let result: [SearchItem]?
}

private struct SearchItem: Decodable, Sendable {
    let bvid: String
    let title: String
    let author: String
    let description: String
    let pic: String
    let duration: String
    let play: Int?
    let pubdate: Int?
}

private struct RelatedVideosResponse: Decodable, Sendable, APIResponse {
    let code: Int
    let message: String
    let data: [RelatedVideoItem]?
}

private struct RelatedVideoItem: Decodable, Sendable {
    let bvid: String
    let title: String?
    let owner: RelatedVideoOwner?
    let description: String?
    let picture: String?
    let duration: Int?
    let statistics: RelatedVideoStatistics?
    let publishedAt: Int?

    enum CodingKeys: String, CodingKey {
        case bvid
        case title
        case owner
        case description = "desc"
        case picture = "pic"
        case duration
        case statistics = "stat"
        case publishedAt = "pubdate"
    }
}

private struct RelatedVideoOwner: Decodable, Sendable {
    let name: String
}

private struct RelatedVideoStatistics: Decodable, Sendable {
    let viewCount: Int

    enum CodingKeys: String, CodingKey {
        case viewCount = "view"
    }
}

private struct PagesResponse: Decodable, Sendable, APIResponse {
    let code: Int
    let message: String
    let data: [VideoPage]?
}

private struct VideoPage: Decodable, Sendable {
    let cid: Int64
    let page: Int
    let part: String
    let duration: Int
}

private struct PlayURLResponse: Decodable, Sendable, APIResponse {
    let code: Int
    let message: String
    let data: PlayURLData?
}

private struct PlayURLData: Decodable, Sendable {
    let dash: DASHData?
}

private struct DASHData: Decodable, Sendable {
    let audio: [DASHAudio]
}

private struct DASHAudio: Decodable, Sendable {
    let id: Int
    let bandwidth: Int
    let baseURL: String?
    let baseURLCamel: String?
    let backupURL: [String]?
    let backupURLCamel: [String]?

    var primaryURL: URL? {
        let candidates = [baseURL, baseURLCamel] + (backupURL ?? []) + (backupURLCamel ?? [])
        return candidates.compactMap { $0 }.compactMap(URL.init(string:)).first
    }

    enum CodingKeys: String, CodingKey {
        case id
        case bandwidth
        case baseURL = "base_url"
        case baseURLCamel = "baseUrl"
        case backupURL = "backup_url"
        case backupURLCamel = "backupUrl"
    }
}

extension String {
    var removingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
