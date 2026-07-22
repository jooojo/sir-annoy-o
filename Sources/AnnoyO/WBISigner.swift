import CryptoKit
import Foundation

enum WBISigner {
    private static let mixinKeyOrder = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]

    static func signedQuery(
        parameters: [String: String],
        imageKey: String,
        subKey: String,
        timestamp: Int
    ) -> String {
        let sourceKey = Array(imageKey + subKey)
        let mixinKey = String(mixinKeyOrder.compactMap { index in
            sourceKey.indices.contains(index) ? sourceKey[index] : nil
        }.prefix(32))

        var values = parameters
        values["wts"] = String(timestamp)

        let query = values.keys.sorted().map { key in
            let value = values[key, default: ""]
                .filter { !"!'()*".contains($0) }
            return "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")

        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(query)&w_rid=\(digest)"
    }

    static func key(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
