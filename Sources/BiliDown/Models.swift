import Foundation

enum CoreState: Equatable {
    case idle
    case missing
    case installing
    case stopped
    case starting
    case running(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "未检查"
        case .missing: "缺少核心"
        case .installing: "安装核心"
        case .stopped: "已停止"
        case .starting: "启动中"
        case .running(let name): name.isEmpty ? "运行中" : "运行中: \(name)"
        case .failed: "异常"
        }
    }

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

enum ParsedVideoSource: Equatable {
    case jijiDownCore
    case ytDLP
}

enum DownloadTaskSource: Equatable {
    case jijiDownCore
    case ytDLP
}

struct ParsedVideo: Identifiable, Equatable {
    let id = UUID()
    var source: ParsedVideoSource = .jijiDownCore
    var sourceURL: String = ""
    var title: String
    var filename: String
    var desc: String
    var upName: String
    var mark: String
    var webLink: String
    var coverData: Data
    var pages: [VideoPage]
}

struct VideoPage: Identifiable, Hashable {
    var id: String { "\(bvid)-\(cid)" }
    var av: Int64
    var bvid: String
    var cid: Int64
    var index: Int32
    var title: String
    var info: [String]
    var url: String? = nil
}

struct VideoQuality: Identifiable, Hashable {
    var id: String
    var qualityID: UInt32
    var title: String
    var codec: Jijidown_Core_VideoType
    var apiType: Jijidown_Core_ApiType
    var bitRate: String
    var streamSize: String

    static let defaultHighest = VideoQuality(
        id: "default-video",
        qualityID: 0,
        title: "默认最高画质",
        codec: .hevc,
        apiType: .web,
        bitRate: "",
        streamSize: ""
    )

    var label: String {
        let detail = [codec.label, bitRate, streamSize].filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? title : "\(apiType.label) \(title) · \(detail)"
    }
}

struct AudioQuality: Identifiable, Hashable {
    var id: String
    var qualityID: UInt32
    var title: String
    var codecText: String
    var apiType: Jijidown_Core_ApiType
    var bitRate: String
    var streamSize: String

    static let defaultHighest = AudioQuality(
        id: "default-audio",
        qualityID: 30280,
        title: "默认最高音质",
        codecText: "AAC",
        apiType: .web,
        bitRate: "",
        streamSize: ""
    )

    var label: String {
        let detail = [codecText, bitRate, streamSize].filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? title : "\(apiType.label) \(title) · \(detail)"
    }
}

struct DownloadTaskItem: Identifiable, Hashable {
    var id: String
    var source: DownloadTaskSource = .jijiDownCore
    var title: String
    var status: Jijidown_Core_TaskStatusType
    var progress: UInt32
    var speed: String
    var eta: String
    var savePath: String
    var videoBadge: String
    var audioBadge: String

    var statusLabel: String { status.label }
    var canPause: Bool { source == .jijiDownCore && status.canPause }
    var canResume: Bool { source == .jijiDownCore && status.canResume }
    var canDelete: Bool { source == .jijiDownCore }
}

struct CoreManifest {
    var sha256: String
    var version: String
}

extension Jijidown_Core_ApiType {
    var label: String {
        switch self {
        case .web: "WEB"
        case .tv: "TV"
        case .app: "APP"
        case .UNRECOGNIZED(let value): "API \(value)"
        }
    }
}

extension Jijidown_Core_VideoType {
    var label: String {
        switch self {
        case .unknown: "未知"
        case .avc: "AVC"
        case .hevc: "HEVC"
        case .av1: "AV1"
        case .UNRECOGNIZED(let value): "Codec \(value)"
        }
    }
}

extension Jijidown_Core_TaskStatusType {
    var label: String {
        switch self {
        case .taskError: "错误"
        case .taskPause: "暂停"
        case .taskRunning: "下载中"
        case .taskWait: "等待"
        case .taskMergeing: "合并中"
        case .taskGenmusic: "提取音频"
        case .taskComplete: "完成"
        case .UNRECOGNIZED(let value): "状态 \(value)"
        }
    }

    var canPause: Bool { self == .taskRunning || self == .taskWait }
    var canResume: Bool { self == .taskPause || self == .taskError }
}
