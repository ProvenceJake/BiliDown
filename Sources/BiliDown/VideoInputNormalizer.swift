import Foundation

enum VideoInputNormalizer {
    static func normalize(_ rawValue: String) -> String? {
        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let bvRange = text.range(of: #"(?i)BV1[1-9A-HJ-NP-Za-km-z]{9}"#, options: .regularExpression) {
            return "https://www.bilibili.com/video/\(text[bvRange])"
        }

        if let avRange = text.range(of: #"(?i)\bav\d+\b"#, options: .regularExpression) {
            return "https://www.bilibili.com/video/\(text[avRange])"
        }

        let lowercased = text.lowercased()
        if lowercased.hasPrefix("https://www.bilibili.com/")
            || lowercased.hasPrefix("http://www.bilibili.com/")
            || lowercased.hasPrefix("https://bilibili.com/")
            || lowercased.hasPrefix("http://bilibili.com/")
            || lowercased.hasPrefix("https://b23.tv/")
            || lowercased.hasPrefix("http://b23.tv/") {
            return text
        }

        if lowercased.hasPrefix("www.bilibili.com/")
            || lowercased.hasPrefix("bilibili.com/")
            || lowercased.hasPrefix("b23.tv/") {
            return "https://\(text)"
        }

        return nil
    }
}
