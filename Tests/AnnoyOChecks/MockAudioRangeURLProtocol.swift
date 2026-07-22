import Foundation

final class MockAudioRangeURLProtocol: URLProtocol, @unchecked Sendable {
    enum ResponseMode {
        case emptyPartialContent
        case fullContent
        case partialContent
    }

    private static let stateLock = NSLock()
    private static var payload = Data()
    private static var responseMode = ResponseMode.partialContent
    private static var activeRequestCount = 0
    private static var recordedMaximumActiveRequestCount = 0
    private static var recordedRanges: [String] = []
    private static var recordedResources: [String] = []
    private static var recordedDeliveredByteCount = 0

    private let lifecycleLock = NSRecursiveLock()
    private var isStopped = false
    private var didFinish = false

    static var maximumActiveRequestCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedMaximumActiveRequestCount
    }

    static var requestedRanges: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedRanges
    }

    static var requestedResources: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedResources
    }

    static var deliveredByteCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedDeliveredByteCount
    }

    static func reset(
        payload: Data,
        responseMode: ResponseMode = .partialContent
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.payload = payload
        self.responseMode = responseMode
        activeRequestCount = 0
        recordedMaximumActiveRequestCount = 0
        recordedRanges = []
        recordedResources = []
        recordedDeliveredByteCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "audio.annoyo.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let rangeHeader = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
        let fixture = Self.beginRequest(path: url.path, range: rangeHeader)
        guard let requestedRange = Self.byteRange(from: rangeHeader, contentLength: fixture.data.count) else {
            finishWithStatus(416, url: url, data: Data())
            return
        }

        let responseData: Data
        let statusCode: Int
        var headers = [
            "Accept-Ranges": "bytes",
            "Content-Type": "audio/mp4",
        ]
        switch fixture.responseMode {
        case .emptyPartialContent:
            responseData = Data()
            statusCode = 206
            headers["Content-Range"] = Self.contentRangeHeader(
                for: requestedRange,
                contentLength: fixture.data.count
            )
        case .fullContent:
            responseData = fixture.data
            statusCode = 200
        case .partialContent:
            responseData = fixture.data.subdata(in: requestedRange)
            statusCode = 206
            headers["Content-Range"] = Self.contentRangeHeader(
                for: requestedRange,
                contentLength: fixture.data.count
            )
        }
        headers["Content-Length"] = String(responseData.count)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        lifecycleLock.lock()
        guard !isStopped else {
            lifecycleLock.unlock()
            finishRequestIfNeeded()
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        lifecycleLock.unlock()
        deliver(responseData, offset: 0)
    }

    override func stopLoading() {
        lifecycleLock.lock()
        isStopped = true
        lifecycleLock.unlock()
        finishRequestIfNeeded()
    }

    private func deliver(_ data: Data, offset: Int) {
        var nextOffset = offset
        while nextOffset < data.count {
            lifecycleLock.lock()
            guard !isStopped else {
                lifecycleLock.unlock()
                finishRequestIfNeeded()
                return
            }
            let end = min(data.count, nextOffset + 16 * 1024)
            let chunk = data.subdata(in: nextOffset..<end)
            Self.recordDelivery(of: chunk.count)
            client?.urlProtocol(self, didLoad: chunk)
            lifecycleLock.unlock()
            nextOffset = end
            Thread.sleep(forTimeInterval: 0.012)
        }

        lifecycleLock.lock()
        if !isStopped {
            client?.urlProtocolDidFinishLoading(self)
        }
        lifecycleLock.unlock()
        finishRequestIfNeeded()
    }

    private func finishWithStatus(_ status: Int, url: URL, data: Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        )!
        lifecycleLock.lock()
        guard !isStopped else {
            lifecycleLock.unlock()
            finishRequestIfNeeded()
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
        lifecycleLock.unlock()
        finishRequestIfNeeded()
    }

    private func finishRequestIfNeeded() {
        lifecycleLock.lock()
        guard !didFinish else {
            lifecycleLock.unlock()
            return
        }
        didFinish = true
        lifecycleLock.unlock()

        Self.stateLock.lock()
        Self.activeRequestCount = max(0, Self.activeRequestCount - 1)
        Self.stateLock.unlock()
    }

    private static func beginRequest(
        path: String,
        range: String
    ) -> (data: Data, responseMode: ResponseMode) {
        stateLock.lock()
        defer { stateLock.unlock() }
        activeRequestCount += 1
        recordedMaximumActiveRequestCount = max(
            recordedMaximumActiveRequestCount,
            activeRequestCount
        )
        recordedRanges.append(range)
        recordedResources.append("\(path) \(range)")
        return (payload, responseMode)
    }

    private static func recordDelivery(of byteCount: Int) {
        stateLock.lock()
        recordedDeliveredByteCount += byteCount
        stateLock.unlock()
    }

    private static func contentRangeHeader(
        for range: Range<Int>,
        contentLength: Int
    ) -> String {
        "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(contentLength)"
    }

    private static func byteRange(
        from header: String,
        contentLength: Int
    ) -> Range<Int>? {
        guard header.hasPrefix("bytes="), contentLength > 0 else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let first = bounds.first,
            let lowerBound = Int(first),
            lowerBound >= 0,
            lowerBound < contentLength
        else { return nil }
        let requestedUpperBound =
            bounds.count > 1 && !bounds[1].isEmpty
            ? Int(bounds[1]).map { $0 + 1 }
            : nil
        return lowerBound..<min(contentLength, requestedUpperBound ?? contentLength)
    }
}
