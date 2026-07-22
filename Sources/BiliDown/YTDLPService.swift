import Foundation

struct YTDLPService {
    struct DownloadProgress: Sendable {
        var percent: UInt32?
        var speed: String
        var eta: String
    }

    var executablePath: String? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/yt-dlp" })
        candidates.append("/opt/homebrew/bin/yt-dlp")
        candidates.append("/usr/local/bin/yt-dlp")
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    func parse(_ url: String, cookies: String? = nil) async throws -> ParsedVideo {
        guard let executablePath else { throw YTDLPError.missingExecutable }
        var arguments = ["--dump-single-json", "--no-warnings", "--skip-download"]
        arguments.append(contentsOf: cookieHeaderArguments(cookies))
        arguments.append(url)

        let result = try await run(
            executablePath: executablePath,
            arguments: arguments,
            progress: nil
        )

        guard result.status == 0 else {
            throw YTDLPError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = Data(result.output.utf8)
        let decoder = JSONDecoder()
        let info = try decoder.decode(YTDLPInfo.self, from: data)
        let entries = info.entries?.filter { ($0.title ?? $0.id ?? "").isEmpty == false } ?? []
        let pages: [VideoPage]

        if entries.isEmpty {
            pages = [makePage(from: info, index: 1, fallbackURL: url)]
        } else {
            pages = entries.enumerated().map { offset, entry in
                makePage(from: entry, index: Int32(offset + 1), fallbackURL: url)
            }
        }

        let coverData = await fetchCoverData(from: info.thumbnail)
        let title = info.title ?? info.fulltitle ?? info.id ?? "哔哩哔哩视频"

        return ParsedVideo(
            source: .ytDLP,
            sourceURL: info.webpageURL ?? url,
            title: title,
            filename: title,
            desc: info.description ?? "",
            upName: info.uploader ?? "",
            mark: info.id ?? "",
            webLink: info.webpageURL ?? url,
            coverData: coverData,
            pages: pages
        )
    }

    func download(
        page: VideoPage,
        downloadDirectory: String,
        ffmpegPath: String,
        audioOnly: Bool,
        cookies: String? = nil,
        progress: (@Sendable (DownloadProgress) async -> Void)?
    ) async throws {
        guard let executablePath else { throw YTDLPError.missingExecutable }

        var arguments = [
            "--newline",
            "--no-warnings",
            "--paths", downloadDirectory,
            "--output", "%(title).200B [%(id)s].%(ext)s",
        ]

        if !ffmpegPath.isEmpty {
            arguments.append(contentsOf: ["--ffmpeg-location", ffmpegLocation(from: ffmpegPath)])
        }

        if audioOnly {
            arguments.append(contentsOf: ["-f", "bestaudio/best", "-x", "--audio-format", "m4a"])
        } else {
            arguments.append(contentsOf: ["-f", "bv*+ba/b", "--merge-output-format", "mp4"])
        }

        arguments.append(contentsOf: cookieHeaderArguments(cookies))
        arguments.append(page.url ?? "https://www.bilibili.com/video/\(page.bvid)")

        let result = try await run(executablePath: executablePath, arguments: arguments, progress: progress)
        guard result.status == 0 else {
            throw YTDLPError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func makePage(from info: YTDLPInfo, index: Int32, fallbackURL: String) -> VideoPage {
        let bvid = extractBVID(from: info.id ?? info.webpageURL ?? fallbackURL) ?? info.id ?? "yt-dlp-\(index)"
        let duration = info.durationString ?? info.duration.map { formatDuration($0) }
        return VideoPage(
            av: 0,
            bvid: bvid,
            cid: Int64(index),
            index: index,
            title: info.title ?? info.fulltitle ?? bvid,
            info: [duration].compactMap { $0 },
            url: info.webpageURL ?? info.url ?? fallbackURL
        )
    }

    private func extractBVID(from text: String) -> String? {
        text.range(of: #"(?i)BV1[1-9A-HJ-NP-Za-km-z]{9}"#, options: .regularExpression).map { String(text[$0]) }
    }

    private func fetchCoverData(from urlString: String?) async -> Data {
        guard let urlString, let url = URL(string: urlString) else { return Data() }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return Data()
            }
            return data
        } catch {
            return Data()
        }
    }

    private func ffmpegLocation(from path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent == "ffmpeg" ? url.deletingLastPathComponent().path : path
    }

    private func cookieHeaderArguments(_ cookies: String?) -> [String] {
        guard var value = cookies?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return []
        }

        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces)
        }

        return ["--add-header", "Cookie: \(value)"]
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func run(
        executablePath: String,
        arguments: [String],
        progress: (@Sendable (DownloadProgress) async -> Void)?
    ) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()

            var output = ""
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                output += chunk
                if let progress {
                    for line in chunk.split(whereSeparator: \.isNewline) {
                        if let update = parseProgressLine(String(line)) {
                            await progress(update)
                        }
                    }
                }
            }

            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
            return CommandResult(status: process.terminationStatus, output: output)
        }.value
    }

    private func parseProgressLine(_ line: String) -> DownloadProgress? {
        guard line.contains("[download]"),
              let percentRange = line.range(of: #"([0-9]+(?:\.[0-9]+)?)%"#, options: .regularExpression)
        else {
            return nil
        }

        let percentText = line[percentRange].dropLast()
        let percent = Double(percentText).map { UInt32(min(100, max(0, $0.rounded()))) }
        let speed = capture(line, pattern: #" at\s+(.+?)\s+ETA "#) ?? ""
        let eta = capture(line, pattern: #" ETA\s+([0-9:]+)"#) ?? ""
        return DownloadProgress(percent: percent, speed: speed, eta: eta)
    }

    private func capture(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}

private struct CommandResult: Sendable {
    var status: Int32
    var output: String
}

private struct YTDLPInfo: Decodable {
    var id: String?
    var title: String?
    var fulltitle: String?
    var uploader: String?
    var description: String?
    var webpageURL: String?
    var url: String?
    var thumbnail: String?
    var durationString: String?
    var duration: Double?
    var entries: [YTDLPInfo]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case fulltitle
        case uploader
        case description
        case webpageURL = "webpage_url"
        case url
        case thumbnail
        case durationString = "duration_string"
        case duration
        case entries
    }
}

enum YTDLPError: LocalizedError {
    case missingExecutable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "未找到 yt-dlp，请先安装: brew install yt-dlp"
        case .commandFailed(let message):
            message.isEmpty ? "yt-dlp 执行失败" : message
        }
    }
}
