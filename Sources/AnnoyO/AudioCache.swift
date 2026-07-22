import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct AudioCacheKey: Hashable, Codable, Sendable {
    let bvid: String
    let cid: Int64
    let representationID: Int

    var fileName: String {
        let safeBVID = bvid.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return "\(safeBVID)-\(cid)-\(representationID)"
    }
}

struct AudioCacheSummary: Equatable, Sendable {
    let usedBytes: Int64
    let limitBytes: Int64
    let itemCount: Int
}

struct AudioCacheSource: Sendable {
    let key: AudioCacheKey
    let url: URL
    let headers: [String: String]
}

struct CachedAudioAsset {
    let asset: AVURLAsset
    let resourceLoader: AudioResourceLoader?
}

final class AudioCache: @unchecked Sendable {
    static let shared = AudioCache()

    private static let prefetchByteLimit = 1_048_576

    private let store: AudioCacheStore
    private let sessionConfiguration: URLSessionConfiguration

    init(
        rootURL: URL? = nil,
        limitBytes: Int64 = 2 * 1024 * 1024 * 1024,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        let cacheRoot = rootURL ?? Self.defaultRootURL
        store = AudioCacheStore(rootURL: cacheRoot, limitBytes: limitBytes)
        self.sessionConfiguration = sessionConfiguration.copy() as? URLSessionConfiguration ?? .default
    }

    func makeAsset(for source: AudioCacheSource) -> CachedAudioAsset {
        if let localURL = store.completeFileURL(for: source.key) {
            return CachedAudioAsset(asset: AVURLAsset(url: localURL), resourceLoader: nil)
        }

        let loader = AudioResourceLoader(
            source: source,
            store: store,
            sessionConfiguration: sessionConfiguration
        )
        let assetURL = URL(string: "annoyo-cache://audio/\(source.key.fileName).m4a")!
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
        return CachedAudioAsset(asset: asset, resourceLoader: loader)
    }

    func prefetch(_ source: AudioCacheSource) async throws {
        if store.completeFileURL(for: source.key) != nil { return }

        let cachedLength =
            store.cachedPrefix(
                for: source.key,
                offset: 0,
                maxLength: Self.prefetchByteLimit
            )?.count ?? 0
        let knownLength = store.contentInfo(for: source.key)?.contentLength
        if cachedLength >= Self.prefetchByteLimit
            || knownLength.map({ Int64(cachedLength) >= $0 }) == true
        {
            return
        }

        var request = URLRequest(url: source.url)
        for (field, value) in source.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.networkServiceType = .background
        request.setValue(
            "bytes=\(cachedLength)-\(Self.prefetchByteLimit - 1)",
            forHTTPHeaderField: "Range"
        )

        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse,
            http.statusCode == 200 || http.statusCode == 206
        else {
            throw AudioCacheError.badHTTPStatus((response as? HTTPURLResponse)?.statusCode)
        }

        let contentRange = parseAudioContentRange(http.value(forHTTPHeaderField: "Content-Range"))
        if http.statusCode == 206, contentRange?.start != Int64(cachedLength) {
            throw AudioCacheError.invalidContentRange
        }
        let responseStart = contentRange?.start ?? 0
        let remainingLimit = max(0, Self.prefetchByteLimit - Int(responseStart))
        var prefetchedData = Data()
        prefetchedData.reserveCapacity(remainingLimit)
        do {
            for try await byte in bytes.prefix(remainingLimit) {
                prefetchedData.append(byte)
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        let contentLength =
            contentRange?.total
            ?? (http.statusCode == 200 && response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        store.updateContentInfo(
            for: source.key,
            contentLength: contentLength,
            mimeType: response.mimeType
        )
        store.write(prefetchedData, for: source.key, at: responseStart)
        store.finishAccess(for: source.key)
    }

    func summary() -> AudioCacheSummary {
        store.summary()
    }

    func clear() {
        store.clear()
    }

    private static var defaultRootURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return
            root
            .appendingPathComponent("AnnoyO", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
    }
}

final class AudioCacheStore: @unchecked Sendable {
    private let rootURL: URL
    private let indexURL: URL
    private let limitBytes: Int64
    private let lock = NSLock()
    private var entries: [String: AudioCacheEntry]

    init(rootURL: URL, limitBytes: Int64) {
        self.rootURL = rootURL
        indexURL = rootURL.appendingPathComponent("index.json")
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode([String: AudioCacheEntry].self, from: data)
        {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    fileprivate func contentInfo(for key: AudioCacheKey) -> CachedContentInfo? {
        lock.withLock {
            guard let entry = entries[key.fileName] else { return nil }
            return CachedContentInfo(contentLength: entry.contentLength, mimeType: entry.mimeType)
        }
    }

    func updateContentInfo(
        for key: AudioCacheKey,
        contentLength: Int64?,
        mimeType: String?
    ) {
        lock.withLock {
            var entry = entries[key.fileName] ?? AudioCacheEntry(key: key)
            if let contentLength, contentLength > 0 { entry.contentLength = contentLength }
            if let mimeType, !mimeType.isEmpty { entry.mimeType = mimeType }
            entry.lastAccess = Date()
            entries[key.fileName] = entry
        }
    }

    func cachedPrefix(for key: AudioCacheKey, offset: Int64, maxLength: Int) -> Data? {
        guard offset >= 0, maxLength > 0 else { return nil }
        return lock.withLock {
            guard var entry = entries[key.fileName],
                let range = entry.ranges.first(where: { $0.lowerBound <= offset && offset < $0.upperBound })
            else { return nil }

            let available = min(Int64(maxLength), range.upperBound - offset)
            guard available > 0,
                let handle = try? FileHandle(forReadingFrom: fileURL(for: key))
            else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: Int(available))
                entry.lastAccess = Date()
                entries[key.fileName] = entry
                return data?.isEmpty == false ? data : nil
            } catch {
                return nil
            }
        }
    }

    func write(_ data: Data, for key: AudioCacheKey, at offset: Int64) {
        guard !data.isEmpty, offset >= 0 else { return }
        lock.withLock {
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let url = fileURL(for: key)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
                var entry = entries[key.fileName] ?? AudioCacheEntry(key: key)
                entry.ranges.append(
                    CachedByteRange(
                        lowerBound: offset,
                        upperBound: offset + Int64(data.count)
                    ))
                entry.ranges = Self.merged(entry.ranges)
                entry.lastAccess = Date()
                entries[key.fileName] = entry
            } catch {
                return
            }
        }
    }

    func completeFileURL(for key: AudioCacheKey) -> URL? {
        lock.withLock {
            guard var entry = entries[key.fileName], entry.isComplete else { return nil }
            let url = fileURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else {
                entries.removeValue(forKey: key.fileName)
                return nil
            }
            entry.lastAccess = Date()
            entries[key.fileName] = entry
            persistLocked()
            return url
        }
    }

    func finishAccess(for key: AudioCacheKey) {
        lock.withLock {
            if var entry = entries[key.fileName] {
                entry.lastAccess = Date()
                entries[key.fileName] = entry
            }
            trimLocked(excluding: key.fileName)
            persistLocked()
        }
    }

    func summary() -> AudioCacheSummary {
        lock.withLock {
            let existing = entries.values.filter {
                FileManager.default.fileExists(atPath: fileURL(for: $0.key).path)
            }
            return AudioCacheSummary(
                usedBytes: existing.reduce(0) { $0 + fileSize(at: fileURL(for: $1.key)) },
                limitBytes: limitBytes,
                itemCount: existing.count
            )
        }
    }

    func clear() {
        lock.withLock {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            entries = [:]
            persistLocked()
        }
    }

    private func fileURL(for key: AudioCacheKey) -> URL {
        rootURL.appendingPathComponent("\(key.fileName).m4a")
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func trimLocked(excluding excludedKey: String) {
        var total = entries.values.reduce(Int64(0)) { partial, entry in
            partial + fileSize(at: fileURL(for: entry.key))
        }
        guard total > limitBytes else { return }

        let evictionCandidates = entries.values
            .filter { $0.key.fileName != excludedKey }
            .sorted { $0.lastAccess < $1.lastAccess }
        for entry in evictionCandidates where total > limitBytes {
            let url = fileURL(for: entry.key)
            total -= fileSize(at: url)
            try? FileManager.default.removeItem(at: url)
            entries.removeValue(forKey: entry.key.fileName)
        }
    }

    private func persistLocked() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func merged(_ ranges: [CachedByteRange]) -> [CachedByteRange] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [CachedByteRange] = []
        for range in sorted where range.upperBound > range.lowerBound {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = CachedByteRange(
                    lowerBound: last.lowerBound,
                    upperBound: max(last.upperBound, range.upperBound)
                )
            } else {
                result.append(range)
            }
        }
        return result
    }
}

final class AudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let delegateQueue = DispatchQueue(label: "io.annoyo.audio-cache-loader")

    private static let originSegmentLength: Int64 = 256 * 1024

    private let key: AudioCacheKey
    private let originURL: URL
    private let headers: [String: String]
    private let store: AudioCacheStore
    private let sessionConfiguration: URLSessionConfiguration
    private let operationQueue: OperationQueue
    private var pendingRequests: [ObjectIdentifier: AudioLoadingContext] = [:]
    private var pendingOrder: [ObjectIdentifier] = []
    private var activeTask: URLSessionDataTask?
    private var activeTransfer: AudioOriginTransfer?
    private lazy var session = URLSession(
        configuration: sessionConfiguration,
        delegate: self,
        delegateQueue: operationQueue
    )

    init(
        source: AudioCacheSource,
        store: AudioCacheStore,
        sessionConfiguration: URLSessionConfiguration
    ) {
        key = source.key
        originURL = source.url
        headers = source.headers
        self.store = store
        self.sessionConfiguration = sessionConfiguration.copy() as? URLSessionConfiguration ?? .default
        operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = delegateQueue
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        fillContentInformation(on: loadingRequest)
        let requestID = ObjectIdentifier(loadingRequest)
        let endOffset: Int64?
        if let dataRequest = loadingRequest.dataRequest {
            endOffset =
                dataRequest.requestsAllDataToEndOfResource
                ? nil
                : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
        } else {
            endOffset = 2
        }
        pendingRequests[requestID] = AudioLoadingContext(
            loadingRequest: loadingRequest,
            endOffset: endOffset
        )
        pendingOrder.removeAll { $0 == requestID }
        pendingOrder.append(requestID)
        processPendingRequests()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let requestID = ObjectIdentifier(loadingRequest)
        removePendingRequest(requestID)
        guard pendingRequests.isEmpty, let activeTask, let activeTransfer else {
            store.finishAccess(for: key)
            return
        }
        activeTransfer.wasCancelledBecauseIdle = true
        activeTask.cancel()
        store.finishAccess(for: key)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard activeTask?.taskIdentifier == dataTask.taskIdentifier,
            let transfer = activeTransfer
        else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse,
            http.statusCode == 200 || http.statusCode == 206
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            transfer.responseError = AudioCacheError.badHTTPStatus(statusCode)
            completionHandler(.cancel)
            return
        }

        let contentRange = parseAudioContentRange(http.value(forHTTPHeaderField: "Content-Range"))
        if http.statusCode == 206, contentRange?.start != transfer.requestedOffset {
            transfer.responseError = AudioCacheError.invalidContentRange
            completionHandler(.cancel)
            return
        }
        let responseStart = contentRange?.start ?? 0
        let contentLength =
            contentRange?.total
            ?? (http.statusCode == 200 && response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        transfer.nextOriginOffset = responseStart
        transfer.contentLength = contentLength
        transfer.mimeType = response.mimeType
        store.updateContentInfo(
            for: key,
            contentLength: contentLength,
            mimeType: response.mimeType
        )
        completionHandler(.allow)
        processPendingRequests()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard activeTask?.taskIdentifier == dataTask.taskIdentifier,
            let transfer = activeTransfer
        else { return }
        store.updateContentInfo(
            for: key,
            contentLength: transfer.contentLength,
            mimeType: transfer.mimeType
        )
        store.write(data, for: key, at: transfer.nextOriginOffset)
        transfer.nextOriginOffset += Int64(data.count)
        transfer.receivedByteCount += data.count
        processPendingRequests()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard activeTask?.taskIdentifier == task.taskIdentifier,
            let transfer = activeTransfer
        else { return }
        activeTask = nil
        activeTransfer = nil

        if transfer.wasCancelledBecauseIdle {
            store.finishAccess(for: key)
            return
        }
        if let failure = transfer.responseError ?? error {
            finishAllPendingRequests(with: failure)
            return
        }
        guard transfer.receivedByteCount > 0 else {
            finishAllPendingRequests(with: AudioCacheError.emptyResponse)
            return
        }
        processPendingRequests()
    }

    private func processPendingRequests() {
        let requestIDs = pendingOrder
        for requestID in requestIDs {
            guard let context = pendingRequests[requestID] else { continue }
            let loadingRequest = context.loadingRequest
            guard !loadingRequest.isCancelled, !loadingRequest.isFinished else {
                removePendingRequest(requestID)
                continue
            }
            fillContentInformation(on: loadingRequest)

            guard let dataRequest = loadingRequest.dataRequest else {
                if store.contentInfo(for: key) != nil {
                    finishPendingRequest(requestID)
                }
                continue
            }

            while true {
                let offset = Self.currentOffset(for: dataRequest)
                let remaining =
                    context.endOffset.map { max(0, $0 - offset) }
                    ?? store.contentInfo(for: key)?.contentLength.map { max(0, $0 - offset) }
                    ?? 1_048_576
                guard remaining > 0 else { break }
                let readLength = Int(min(Int64(1_048_576), remaining))
                guard
                    let cached = store.cachedPrefix(
                        for: key,
                        offset: offset,
                        maxLength: readLength
                    )
                else { break }
                dataRequest.respond(with: cached)
            }

            let currentOffset = Self.currentOffset(for: dataRequest)
            let reachedRequestedEnd = context.endOffset.map { currentOffset >= $0 } ?? false
            let reachedResourceEnd =
                store.contentInfo(for: key)?.contentLength
                .map { currentOffset >= $0 } ?? false
            if reachedRequestedEnd || reachedResourceEnd {
                finishPendingRequest(requestID)
            }
        }

        guard activeTask == nil,
            let context = pendingOrder.reversed().compactMap({ pendingRequests[$0] }).first
        else { return }

        let offset = context.loadingRequest.dataRequest.map(Self.currentOffset(for:)) ?? 0
        let knownLength = store.contentInfo(for: key)?.contentLength
        let requestedEnd = context.endOffset ?? knownLength
        let segmentEnd = min(
            requestedEnd ?? offset + Self.originSegmentLength,
            offset + Self.originSegmentLength
        )
        guard segmentEnd > offset else {
            finishPendingRequest(ObjectIdentifier(context.loadingRequest))
            processPendingRequests()
            return
        }

        var request = URLRequest(url: originURL)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("bytes=\(offset)-\(segmentEnd - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        activeTransfer = AudioOriginTransfer(requestedOffset: offset)
        activeTask = task
        task.resume()
    }

    private func finishPendingRequest(_ requestID: ObjectIdentifier) {
        guard let context = pendingRequests[requestID] else { return }
        removePendingRequest(requestID)
        guard !context.loadingRequest.isCancelled, !context.loadingRequest.isFinished else { return }
        context.loadingRequest.finishLoading()
        store.finishAccess(for: key)
    }

    private func finishAllPendingRequests(with error: Error) {
        let contexts = Array(pendingRequests.values)
        pendingRequests.removeAll()
        pendingOrder.removeAll()
        for context in contexts where !context.loadingRequest.isCancelled && !context.loadingRequest.isFinished {
            context.loadingRequest.finishLoading(with: error)
        }
        store.finishAccess(for: key)
    }

    private func removePendingRequest(_ requestID: ObjectIdentifier) {
        pendingRequests.removeValue(forKey: requestID)
        pendingOrder.removeAll { $0 == requestID }
    }

    private func fillContentInformation(on loadingRequest: AVAssetResourceLoadingRequest) {
        guard let request = loadingRequest.contentInformationRequest,
            let info = store.contentInfo(for: key)
        else { return }
        if let contentLength = info.contentLength {
            request.contentLength = contentLength
        }
        request.isByteRangeAccessSupported = true
        if let mimeType = info.mimeType,
            !["application/octet-stream", "audio/mp4", "audio/x-m4a", "application/mp4"].contains(mimeType),
            let contentType = UTType(mimeType: mimeType)
        {
            request.contentType = contentType.identifier
        } else {
            request.contentType = UTType.mpeg4Audio.identifier
        }
    }

    private static func currentOffset(for dataRequest: AVAssetResourceLoadingDataRequest) -> Int64 {
        dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
    }
}

private func parseAudioContentRange(_ value: String?) -> (start: Int64, total: Int64)? {
    guard let value,
        let rangeAndTotal = value.split(separator: " ").last,
        let slash = rangeAndTotal.firstIndex(of: "/"),
        let dash = rangeAndTotal[..<slash].firstIndex(of: "-"),
        let start = Int64(rangeAndTotal[..<dash]),
        let total = Int64(rangeAndTotal[rangeAndTotal.index(after: slash)...])
    else { return nil }
    return (start, total)
}

private final class AudioLoadingContext: @unchecked Sendable {
    let loadingRequest: AVAssetResourceLoadingRequest
    let endOffset: Int64?

    init(loadingRequest: AVAssetResourceLoadingRequest, endOffset: Int64?) {
        self.loadingRequest = loadingRequest
        self.endOffset = endOffset
    }
}

private final class AudioOriginTransfer: @unchecked Sendable {
    let requestedOffset: Int64
    var nextOriginOffset: Int64
    var contentLength: Int64?
    var mimeType: String?
    var responseError: Error?
    var wasCancelledBecauseIdle = false
    var receivedByteCount = 0

    init(requestedOffset: Int64) {
        self.requestedOffset = requestedOffset
        nextOriginOffset = requestedOffset
    }
}

private enum AudioCacheError: LocalizedError {
    case badHTTPStatus(Int?)
    case emptyResponse
    case invalidContentRange

    var errorDescription: String? {
        switch self {
        case .badHTTPStatus(let statusCode):
            if let statusCode {
                return "音频 CDN 请求失败（HTTP \(statusCode)）"
            }
            return "音频 CDN 返回了无效响应"
        case .emptyResponse:
            return "音频 CDN 未返回任何数据"
        case .invalidContentRange:
            return "音频 CDN 返回了错位的分段数据"
        }
    }
}

private struct CachedContentInfo {
    let contentLength: Int64?
    let mimeType: String?
}

private struct AudioCacheEntry: Codable {
    let key: AudioCacheKey
    var contentLength: Int64?
    var mimeType: String?
    var ranges: [CachedByteRange]
    var lastAccess: Date

    init(key: AudioCacheKey) {
        self.key = key
        contentLength = nil
        mimeType = nil
        ranges = []
        lastAccess = Date()
    }

    var isComplete: Bool {
        guard let contentLength, contentLength > 0, let first = ranges.first else { return false }
        return first.lowerBound == 0 && first.upperBound >= contentLength
    }
}

private struct CachedByteRange: Codable {
    let lowerBound: Int64
    let upperBound: Int64
}

extension NSLock {
    fileprivate func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
