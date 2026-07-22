import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

struct JiJiDownService {
    var host = "127.0.0.1"
    var port = 4000
    var metadata: Metadata = ["client_sdk": "JiJiDownSwift/1.0.0"]

    func ping() async throws -> String {
        try await withClient { client in
            let status = Jijidown_Core_Status.Client(wrapping: client)
            let pong = try await status.ping(Google_Protobuf_Empty(), metadata: metadata)
            return pong.serverName.isEmpty ? pong.osSystemName : pong.serverName
        }
    }

    func userInfo() async throws -> Jijidown_Core_UserInfoReply {
        try await withClient { client in
            let user = Jijidown_Core_User.Client(wrapping: client)
            return try await user.info(Google_Protobuf_Empty(), metadata: metadata)
        }
    }

    func importCookies(_ cookies: String, accessToken: String) async throws {
        try await withClient { client in
            let user = Jijidown_Core_User.Client(wrapping: client)
            var request = Jijidown_Core_UserImportCookieReq()
            request.cookies = cookies
            request.accessToken = accessToken
            _ = try await user.importCookie(request, metadata: metadata)
        }
    }

    func parseVideo(_ url: String) async throws -> ParsedVideo {
        try await withClient { client in
            let bvideo = Jijidown_Core_Bvideo.Client(wrapping: client)
            var request = Jijidown_Core_BvideoContentReq()
            request.content = url
            let reply = try await bvideo.info(request, metadata: metadata)

            var pages: [VideoPage] = []
            var seen = Set<String>()
            for block in reply.block {
                for page in block.list {
                    let key = "\(page.pageBv)-\(page.pageCid)"
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    pages.append(VideoPage(
                        av: page.pageAv,
                        bvid: page.pageBv,
                        cid: page.pageCid,
                        index: page.pageIndex,
                        title: page.pageTitle.isEmpty ? reply.videoTitle : page.pageTitle,
                        info: page.pageInfo
                    ))
                }
            }

            return ParsedVideo(
                title: reply.videoTitle,
                filename: reply.videoFilename,
                desc: reply.videoDesc,
                upName: reply.upName,
                mark: reply.blinkResult.mark,
                webLink: reply.blinkResult.webLink,
                coverData: reply.videoCover,
                pages: pages
            )
        }
    }

    func qualities(for page: VideoPage) async throws -> ([VideoQuality], [AudioQuality]) {
        try await withClient { client in
            let bvideo = Jijidown_Core_Bvideo.Client(wrapping: client)
            var request = Jijidown_Core_BvideoAllQualityReq()
            request.bvid = page.bvid
            request.cid = page.cid
            let reply = try await bvideo.allQuality(request, metadata: metadata)

            let videos = reply.video.map { item in
                VideoQuality(
                    id: "v-\(item.apiType.rawValue)-\(item.qualityID)-\(item.codec.rawValue)",
                    qualityID: item.qualityID,
                    title: item.qualityText,
                    codec: item.codec,
                    apiType: item.apiType,
                    bitRate: item.bitRate,
                    streamSize: item.streamSize
                )
            }
            .sorted {
                if $0.qualityID == $1.qualityID {
                    return $0.codec.rawValue > $1.codec.rawValue
                }
                return $0.qualityID > $1.qualityID
            }

            let audios = reply.audio.map { item in
                AudioQuality(
                    id: "a-\(item.apiType.rawValue)-\(item.qualityID)-\(item.codecText)",
                    qualityID: item.qualityID,
                    title: item.qualityText,
                    codecText: item.codecText,
                    apiType: item.apiType,
                    bitRate: item.bitRate,
                    streamSize: item.streamSize
                )
            }
            .sorted { $0.qualityID > $1.qualityID }

            return ([.defaultHighest] + videos, [.defaultHighest] + audios)
        }
    }

    func createTasks(
        pages: [VideoPage],
        videoQuality: VideoQuality,
        audioQuality: AudioQuality,
        baseTitle: String,
        audioOnly: Bool
    ) async throws {
        try await withClient { client in
            let task = Jijidown_Core_Task.Client(wrapping: client)
            var batch = Jijidown_Core_TaskNewBatchReq()

            for (index, page) in pages.enumerated() {
                var request = Jijidown_Core_TaskNewReq()
                request.bvid = page.bvid
                request.cid = page.cid
                request.videoQuality = videoQuality.qualityID
                request.audioQuality = audioQuality.qualityID
                request.videoCodec = videoQuality.codec
                request.apiType = videoQuality.apiType
                request.saveFilename = Self.makeSaveName(baseTitle: baseTitle, page: page, pageCount: pages.count)
                request.audioOnly = audioOnly
                request.callback = UInt64(index + 1)
                batch.newTasks.append(request)
            }

            let reply = try await task.newBatch(batch, metadata: metadata)
            let errors = reply.taskCreationStatus.filter { !$0.err.isEmpty }
            if let first = errors.first {
                throw ServiceError.taskCreation(first.err)
            }
        }
    }

    func tasks() async throws -> [DownloadTaskItem] {
        try await withClient { client in
            let task = Jijidown_Core_Task.Client(wrapping: client)
            let statuses: [Jijidown_Core_TaskStatusType] = [
                .taskRunning, .taskWait, .taskMergeing, .taskGenmusic, .taskPause, .taskError, .taskComplete
            ]
            var merged: [String: DownloadTaskItem] = [:]

            for status in statuses {
                var request = Jijidown_Core_TaskListReq()
                request.taskStatus = status
                let reply = try await task.list(request, metadata: metadata)
                for item in reply.tasks {
                    let taskItem = DownloadTaskItem(
                        id: item.taskID,
                        title: item.taskTitle,
                        status: item.taskStatus,
                        progress: item.progress.progress,
                        speed: item.progress.downloadSpeed,
                        eta: item.progress.eta,
                        savePath: item.savePath,
                        videoBadge: item.videoBadge,
                        audioBadge: item.audioBadge
                    )
                    merged[item.taskID] = taskItem
                }
            }

            return merged.values.sorted {
                if $0.status == $1.status {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.status.rawValue < $1.status.rawValue
            }
        }
    }

    func control(taskID: String, action: Jijidown_Core_TaskDo) async throws {
        try await withClient { client in
            let task = Jijidown_Core_Task.Client(wrapping: client)
            var request = Jijidown_Core_TaskControlReq()
            request.taskID = taskID
            request.do = action
            _ = try await task.control(request, metadata: metadata)
        }
    }

    private func withClient<Result: Sendable>(
        _ body: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .dns(host: host, port: port),
                transportSecurity: .plaintext
            )
        ) { client in
            try await body(client)
        }
    }

    private static func makeSaveName(baseTitle: String, page: VideoPage, pageCount: Int) -> String {
        let raw = pageCount > 1 ? "\(baseTitle) - P\(page.index) \(page.title)" : baseTitle
        return raw
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: ":", with: "：")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ServiceError: LocalizedError {
    case taskCreation(String)

    var errorDescription: String? {
        switch self {
        case .taskCreation(let message): message
        }
    }
}
