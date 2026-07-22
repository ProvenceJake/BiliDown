import CryptoKit
import Foundation

actor CoreManager {
    private let fileManager = FileManager.default
    private var process: Process?
    private var logHandle: FileHandle?

    let port = 4000
    let coreURL = URL(string: "https://jj.xn--5nx14y.top/PC/ReWPF/core/JiJiDownCore-darwin-arm64")!
    let hashURL = URL(string: "https://jj.xn--5nx14y.top/PC/ReWPF/core/JiJiDownCore-hash.txt")!

    var appSupportURL: URL {
        get throws {
            try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("BiliDown", isDirectory: true)
        }
    }

    var coreDirectoryURL: URL {
        get throws { try appSupportURL.appendingPathComponent("Core", isDirectory: true) }
    }

    var tempDirectoryURL: URL {
        get throws { try appSupportURL.appendingPathComponent("Temp", isDirectory: true) }
    }

    var logDirectoryURL: URL {
        get throws { try appSupportURL.appendingPathComponent("Logs", isDirectory: true) }
    }

    var coreBinaryURL: URL {
        get throws { try coreDirectoryURL.appendingPathComponent("JiJiDownCore-darwin-arm64") }
    }

    var defaultDownloadDirectoryURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("BiliDown", isDirectory: true)
    }

    var configURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("JiJiDown", isDirectory: true)
            .appendingPathComponent("config.yaml")
    }

    func isCoreInstalled() -> Bool {
        guard let binary = try? coreBinaryURL else { return false }
        return fileManager.isExecutableFile(atPath: binary.path)
    }

    func ensureDirectories(downloadDirectory: String) throws {
        let directories = [
            try appSupportURL,
            try coreDirectoryURL,
            try tempDirectoryURL,
            try logDirectoryURL,
            configURL.deletingLastPathComponent(),
            URL(fileURLWithPath: downloadDirectory, isDirectory: true),
        ]

        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func fetchManifest() async throws -> CoreManifest {
        let (data, _) = try await URLSession.shared.data(from: hashURL)
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 3, parts[2] == "JiJiDownCore-darwin-arm64" {
                return CoreManifest(sha256: parts[0], version: parts[1])
            }
        }
        throw CoreError.manifestMissing
    }

    func installCore() async throws -> CoreManifest {
        try ensureDirectories(downloadDirectory: defaultDownloadDirectoryURL.path)
        let manifest = try await fetchManifest()
        let (temporaryURL, _) = try await URLSession.shared.download(from: coreURL)
        let digest = try sha256Hex(for: temporaryURL)

        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            try? fileManager.removeItem(at: temporaryURL)
            throw CoreError.shaMismatch(expected: manifest.sha256, actual: digest)
        }

        let binaryURL = try coreBinaryURL
        if fileManager.fileExists(atPath: binaryURL.path) {
            try fileManager.removeItem(at: binaryURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: binaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: binaryURL.path
        )
        return manifest
    }

    func writeConfig(downloadDirectory: String, ffmpegPath: String) throws {
        try ensureDirectories(downloadDirectory: downloadDirectory)
        let config = """
        portable: false
        log-level: warning
        external-controller-port:
            grpc: \(port)
            grpc-web: 0
            restful-api: 64001
        external-ui: ""
        secret: ""
        user-info:
            raw-access-token: ""
            raw-cookies: ""
            hide-nickname: false
        download-task:
            temp-dir: \(yamlQuote(try tempDirectoryURL.path))
            download-dir: \(yamlQuote(downloadDirectory))
            ffmpeg-path: \(yamlQuote(ffmpegPath))
            max-task: 2
            download-speed-limit: 0
            disable-mcdn: true
        jdm:
            max-retry: 0
            retry-wait: 0
            part-workers: 2
            session-workers: 2
            min-split-size: 0
            proxy-addr: ""
            check-best-mirror: true
            cache-in-ram: false
            cache-in-ram-limit: 512
            insecure-skip-verify: false
            certs-file-path: ""

        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func start(downloadDirectory: String, ffmpegPath: String) async throws {
        if let process {
            if process.isRunning { return }
            self.process = nil
            try? logHandle?.close()
            logHandle = nil
        }
        guard isCoreInstalled() else { throw CoreError.coreMissing }

        try writeConfig(downloadDirectory: downloadDirectory, ffmpegPath: ffmpegPath)

        let logURL = try logDirectoryURL.appendingPathComponent("core-\(Int(Date().timeIntervalSince1970)).log")
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = try coreBinaryURL
        process.currentDirectoryURL = try coreDirectoryURL
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            try? handle.close()
            throw error
        }

        self.logHandle = handle
        self.process = process
    }

    func stop() {
        guard let process else {
            try? logHandle?.close()
            logHandle = nil
            return
        }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        self.process = nil
        try? logHandle?.close()
        logHandle = nil
    }

    func findFFmpeg() -> String? {
        var candidates: [String] = []
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/ffmpeg" })
        candidates.append("/opt/homebrew/bin/ffmpeg")
        candidates.append("/usr/local/bin/ffmpeg")
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum CoreError: LocalizedError {
    case coreMissing
    case manifestMissing
    case shaMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .coreMissing:
            "JiJiDownCore 尚未安装"
        case .manifestMissing:
            "没有在官方 hash 文件中找到 arm64 核心"
        case .shaMismatch(let expected, let actual):
            "核心校验失败，期望 \(expected)，实际 \(actual)"
        }
    }
}
