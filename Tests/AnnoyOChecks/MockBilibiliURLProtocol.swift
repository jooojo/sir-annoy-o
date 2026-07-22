import Foundation

final class MockBilibiliURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.contains("bilibili.com") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let responseBody: String
        var headers = ["Content-Type": "application/json"]
        switch url.path {
        case "/x/passport-login/web/qrcode/generate":
            responseBody = #"{"code":0,"message":"0","data":{"url":"https://passport.bilibili.com/mock-login","qrcode_key":"mock-key"}}"#
        case "/x/passport-login/web/qrcode/poll":
            headers["Set-Cookie"] = "SESSDATA=test-session; Domain=.bilibili.com; Path=/; Secure; HttpOnly"
            responseBody = #"{"code":0,"message":"0","data":{"code":0}}"#
        case "/x/frontend/finger/spi":
            responseBody = #"{"code":0,"message":"ok","data":{"b_3":"mock-device","b_4":"mock-device-4"}}"#
        case "/x/web-interface/nav":
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let isLoggedIn = cookie.contains("SESSDATA=test-session")
            responseBody = """
            {"code":\(isLoggedIn ? 0 : -101),"message":"\(isLoggedIn ? "0" : "账号未登录")","data":{
              "isLogin":\(isLoggedIn),"uname":"\(isLoggedIn ? "测试用户" : "")","face":"",
              "wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"}
            }}
            """
        case "/x/web-interface/search/type":
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "page" })?
                .value ?? "1"
            let results: String
            switch page {
            case "1":
                results = """
                [
                  {"bvid":"BV1PAGE1A","title":"第一页 A","author":"分页 UP","description":"","pic":"","duration":"03:01","play":100,"pubdate":1700000000},
                  {"bvid":"BV1PAGE1B","title":"第一页 B","author":"分页 UP","description":"","pic":"","duration":"03:02","play":200,"pubdate":1700000001}
                ]
                """
            case "2":
                results = """
                [
                  {"bvid":"BV1PAGE1B","title":"第一页 B 重复项","author":"分页 UP","description":"","pic":"","duration":"03:02","play":200,"pubdate":1700000001},
                  {"bvid":"BV1PAGE2A","title":"第二页 A","author":"分页 UP","description":"","pic":"","duration":"03:03","play":300,"pubdate":1700000002}
                ]
                """
            default:
                results = "[]"
            }
            responseBody = """
            {"code":0,"message":"0","data":{"result":\(results)}}
            """
        case "/x/web-interface/archive/related":
            responseBody = """
            {"code":0,"message":"OK","data":[{
              "bvid":"BV1RELATEDTOP","title":"推荐 Top 1","owner":{"name":"推荐 UP"},
              "desc":"自动推荐","pic":"http://i0.hdslb.com/mock.jpg","duration":160,
              "stat":{"view":439563},"pubdate":1700000123
            }]}
            """
        default:
            responseBody = #"{"code":-404,"message":"mock route not found"}"#
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
