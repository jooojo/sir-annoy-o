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

struct CachedAudioAsset {
    let asset: AVURLAsset
    let resourceLoader: AudioResourceLoader?
}

final class AudioCache: @unchecked Sendable {
    static let shared = AudioCache()

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

    func makeAsset(
        key: AudioCacheKey,
        originURL: URL,
        headers: [String: String]
    ) -> CachedAudioAsset {
        if let localURL = store.completeFileURL(for: key) {
            return CachedAudioAsset(asset: AVURLAsset(url: localURL), resourceLoader: nil)
        }

        let loader = AudioResourceLoader(
            key: key,
            originURL: originURL,
            headers: headers,
            store: store,
            sessionConfiguration: sessionConfiguration
        )
        let assetURL = URL(string: "annoyo-cache://audio/\(key.fileName).m4a")!
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
        return CachedAudioAsset(asset: asset, resourceLoader: loader)
    }

    func summary() -> AudioCacheSummary {
        store.summary()
    }

    func clear() {
        store.clear()
    }

    private static var defaultRootURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root
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
                entry.ranges.append(CachedByteRange(
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

    private let key: AudioCacheKey
    private let originURL: URL
    private let headers: [String: String]
    private let store: AudioCacheStore
    private let sessionConfiguration: URLSessionConfiguration
    private let operationQueue: OperationQueue
    private var contexts: [Int: AudioLoadingContext] = [:]
    private var requestTasks: [ObjectIdentifier: Int] = [:]
    private lazy var session = URLSession(
        configuration: sessionConfiguration,
        delegate: self,
        delegateQueue: operationQueue
    )

    init(
        key: AudioCacheKey,
        originURL: URL,
        headers: [String: String],
        store: AudioCacheStore,
        sessionConfiguration: URLSessionConfiguration
    ) {
        self.key = key
        self.originURL = originURL
        self.headers = headers
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

        if let dataRequest = loadingRequest.dataRequest {
            let start = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
            let requestedEnd = dataRequest.requestsAllDataToEndOfResource
                ? nil
                : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
            let cachedReadLength = requestedEnd.map { max(0, min(Int64(1_048_576), $0 - start)) }
                ?? 1_048_576
            if let cached = store.cachedPrefix(
                for: key,
                offset: start,
                maxLength: Int(cachedReadLength)
            ) {
                dataRequest.respond(with: cached)
            }

            let nextOffset = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : start
            if let requestedEnd, nextOffset >= requestedEnd {
                loadingRequest.finishLoading()
                store.finishAccess(for: key)
                return true
            }
            startNetworkRequest(
                loadingRequest,
                offset: nextOffset,
                endOffset: requestedEnd
            )
        } else {
            startNetworkRequest(loadingRequest, offset: 0, endOffset: 2)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let requestID = ObjectIdentifier(loadingRequest)
        guard let taskID = requestTasks.removeValue(forKey: requestID),
              let context = contexts.removeValue(forKey: taskID)
        else { return }
        context.task?.cancel()
        store.finishAccess(for: key)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let context = contexts[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206
        else {
            context.responseError = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }

        let contentRange = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
        let responseStart = contentRange?.start ?? 0
        let contentLength = contentRange?.total
            ?? (http.statusCode == 200 && response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        context.nextOriginOffset = responseStart
        context.skipBytes = max(0, context.requestedOffset - responseStart)
        context.contentLength = contentLength
        context.mimeType = response.mimeType
        store.updateContentInfo(
            for: key,
            contentLength: contentLength,
            mimeType: response.mimeType
        )
        fillContentInformation(on: context.loadingRequest)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let context = contexts[dataTask.taskIdentifier] else { return }
        store.updateContentInfo(
            for: key,
            contentLength: context.contentLength,
            mimeType: context.mimeType
        )
        store.write(data, for: key, at: context.nextOriginOffset)
        context.nextOriginOffset += Int64(data.count)

        var responseData = data
        if context.skipBytes > 0 {
            let skipped = min(Int64(responseData.count), context.skipBytes)
            responseData.removeFirst(Int(skipped))
            context.skipBytes -= skipped
        }
        if let endOffset = context.endOffset,
           let dataRequest = context.loadingRequest.dataRequest
        {
            let remaining = max(0, endOffset - dataRequest.currentOffset)
            if Int64(responseData.count) > remaining {
                responseData = Data(responseData.prefix(Int(remaining)))
            }
        }
        if !responseData.isEmpty {
            context.loadingRequest.dataRequest?.respond(with: responseData)
        }

        if let endOffset = context.endOffset,
           let currentOffset = context.loadingRequest.dataRequest?.currentOffset,
           currentOffset >= endOffset
        {
            context.loadingRequest.finishLoading()
            contexts.removeValue(forKey: dataTask.taskIdentifier)
            requestTasks.removeValue(forKey: ObjectIdentifier(context.loadingRequest))
            store.finishAccess(for: key)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let context = contexts.removeValue(forKey: task.taskIdentifier) else { return }
        requestTasks.removeValue(forKey: ObjectIdentifier(context.loadingRequest))
        store.finishAccess(for: key)
        guard !context.loadingRequest.isCancelled, !context.loadingRequest.isFinished else { return }
        if let failure = context.responseError ?? error {
            context.loadingRequest.finishLoading(with: failure)
        } else {
            context.loadingRequest.finishLoading()
        }
    }

    private func startNetworkRequest(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        offset: Int64,
        endOffset: Int64?
    ) {
        var request = URLRequest(url: originURL)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let endOffset {
            request.setValue("bytes=\(offset)-\(max(offset, endOffset - 1))", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        let context = AudioLoadingContext(
            loadingRequest: loadingRequest,
            requestedOffset: offset,
            endOffset: endOffset,
            task: task
        )
        contexts[task.taskIdentifier] = context
        requestTasks[ObjectIdentifier(loadingRequest)] = task.taskIdentifier
        task.resume()
    }

    private func fillContentInformation(on loadingRequest: AVAssetResourceLoadingRequest) {
        guard let request = loadingRequest.contentInformationRequest,
              let info = store.contentInfo(for: key)
        else { return }
        if let contentLength = info.contentLength {
            request.contentLength = contentLength
        }
        request.isByteRangeAccessSupported = true
        if let mimeType = info.mimeType, let contentType = UTType(mimeType: mimeType) {
            request.contentType = contentType.identifier
        } else {
            request.contentType = UTType.mpeg4Audio.identifier
        }
    }

    private static func parseContentRange(_ value: String?) -> (start: Int64, total: Int64)? {
        guard let value,
              let rangeAndTotal = value.split(separator: " ").last,
              let slash = rangeAndTotal.firstIndex(of: "/"),
              let dash = rangeAndTotal[..<slash].firstIndex(of: "-"),
              let start = Int64(rangeAndTotal[..<dash]),
              let total = Int64(rangeAndTotal[rangeAndTotal.index(after: slash)...])
        else { return nil }
        return (start, total)
    }
}

private final class AudioLoadingContext: @unchecked Sendable {
    let loadingRequest: AVAssetResourceLoadingRequest
    let requestedOffset: Int64
    let endOffset: Int64?
    weak var task: URLSessionDataTask?
    var nextOriginOffset: Int64
    var skipBytes: Int64 = 0
    var contentLength: Int64?
    var mimeType: String?
    var responseError: Error?

    init(
        loadingRequest: AVAssetResourceLoadingRequest,
        requestedOffset: Int64,
        endOffset: Int64?,
        task: URLSessionDataTask
    ) {
        self.loadingRequest = loadingRequest
        self.requestedOffset = requestedOffset
        self.endOffset = endOffset
        self.task = task
        nextOriginOffset = requestedOffset
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

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
