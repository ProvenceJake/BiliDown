import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var coreState: CoreState = .idle
    @Published var statusMessage = ""
    @Published var inputURL = ""
    @Published var parsedVideo: ParsedVideo?
    @Published var selectedPageIDs = Set<String>()
    @Published var videoQualities: [VideoQuality] = [.defaultHighest]
    @Published var audioQualities: [AudioQuality] = [.defaultHighest]
    @Published var selectedVideoQualityID = VideoQuality.defaultHighest.id
    @Published var selectedAudioQualityID = AudioQuality.defaultHighest.id
    @Published var audioOnly = false
    @Published var tasks: [DownloadTaskItem] = []
    @Published var isBusy = false
    @Published var isCoreInstalled = false
    @Published var ffmpegPath = ""
    @Published var downloadDirectory = ""
    @Published var cookies = ""
    @Published var accessToken = ""
    @Published var userLabel = "未登录"

    private let coreManager = CoreManager()
    private let service = JiJiDownService()
    private let ytDLPService = YTDLPService()
    private var pollingTask: _Concurrency.Task<Void, Never>?
    private var localTasks: [String: DownloadTaskItem] = [:]
    private let defaults = UserDefaults.standard

    deinit {
        pollingTask?.cancel()
    }

    func bootstrap() async {
        let defaultDirectory = await coreManager.defaultDownloadDirectoryURL.path
        let detectedFFmpeg = await coreManager.findFFmpeg() ?? ""
        downloadDirectory = defaults.string(forKey: "downloadDirectory") ?? defaultDirectory
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? detectedFFmpeg
        cookies = defaults.string(forKey: "cookies") ?? ""
        accessToken = defaults.string(forKey: "accessToken") ?? ""
        isCoreInstalled = await coreManager.isCoreInstalled()
        coreState = isCoreInstalled ? .stopped : .missing
        if ffmpegPath.isEmpty {
            statusMessage = "未检测到 ffmpeg，可用 Homebrew 安装或手动指定路径"
        }
    }

    func savePreferences() {
        defaults.set(downloadDirectory, forKey: "downloadDirectory")
        defaults.set(ffmpegPath, forKey: "ffmpegPath")
        defaults.set(cookies, forKey: "cookies")
        defaults.set(accessToken, forKey: "accessToken")
    }

    func installCore() async {
        isBusy = true
        coreState = .installing
        defer { isBusy = false }
        do {
            let manifest = try await coreManager.installCore()
            isCoreInstalled = true
            coreState = .stopped
            statusMessage = "核心已安装: \(manifest.version)"
        } catch {
            coreState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func startCore() async {
        savePreferences()
        isBusy = true
        coreState = .starting
        defer { isBusy = false }

        do {
            if !(await coreManager.isCoreInstalled()) {
                _ = try await coreManager.installCore()
                isCoreInstalled = true
            }
            try await coreManager.start(downloadDirectory: downloadDirectory, ffmpegPath: ffmpegPath)
            let name = try await waitForPing()
            coreState = .running(name)
            statusMessage = "核心已启动，监听 127.0.0.1:\(coreManager.port)"
            await refreshUserInfo()
            startPolling()
        } catch {
            pollingTask?.cancel()
            pollingTask = nil
            await coreManager.stop()
            let message = friendlyErrorMessage(for: error)
            coreState = .failed(message)
            statusMessage = message
        }
    }

    func stopCore() {
        pollingTask?.cancel()
        pollingTask = nil
        Task {
            await coreManager.stop()
            await MainActor.run {
                coreState = isCoreInstalled ? .stopped : .missing
                statusMessage = "核心已停止"
            }
        }
    }

    func shutdown() async {
        pollingTask?.cancel()
        pollingTask = nil
        await coreManager.stop()
    }

    func parseURL() async {
        guard let url = VideoInputNormalizer.normalize(inputURL) else {
            statusMessage = "请输入完整的哔哩哔哩视频链接、b23.tv 短链、BV 号或 av 号"
            return
        }

        await ensureCoreRunning()

        isBusy = true
        defer { isBusy = false }

        if coreState.isRunning {
            do {
                let video = try await service.parseVideo(url)
                applyParsedVideo(video)
                if let firstPage = video.pages.first {
                    let qualities = try await service.qualities(for: firstPage)
                    videoQualities = qualities.0
                    audioQualities = qualities.1
                    selectedVideoQualityID = qualities.0.first?.id ?? VideoQuality.defaultHighest.id
                    selectedAudioQualityID = qualities.1.first?.id ?? AudioQuality.defaultHighest.id
                }
                statusMessage = "已解析: \(video.title)"
                return
            } catch {
                guard shouldFallbackToYTDLP(for: error) else {
                    statusMessage = friendlyErrorMessage(for: error)
                    return
                }
            }
        }

        do {
            let video = try await ytDLPService.parse(url, cookies: cookies)
            applyParsedVideo(video)
            videoQualities = [.defaultHighest]
            audioQualities = [.defaultHighest]
            selectedVideoQualityID = VideoQuality.defaultHighest.id
            selectedAudioQualityID = AudioQuality.defaultHighest.id
            statusMessage = "已用 yt-dlp 解析: \(video.title)"
        } catch {
            statusMessage = friendlyErrorMessage(for: error)
        }
    }

    func downloadSelected() async {
        guard let parsedVideo else { return }
        let pages = parsedVideo.pages.filter { selectedPageIDs.contains($0.id) }
        guard !pages.isEmpty else {
            statusMessage = "请选择至少一个分 P"
            return
        }
        guard let videoQuality = videoQualities.first(where: { $0.id == selectedVideoQualityID }),
              let audioQuality = audioQualities.first(where: { $0.id == selectedAudioQualityID })
        else {
            statusMessage = "清晰度选择无效"
            return
        }

        if parsedVideo.source == .ytDLP {
            startYTDLPDownloads(pages: pages)
            return
        }

        await ensureCoreRunning()
        guard coreState.isRunning else { return }

        isBusy = true
        defer { isBusy = false }
        do {
            try await service.createTasks(
                pages: pages,
                videoQuality: videoQuality,
                audioQuality: audioQuality,
                baseTitle: parsedVideo.title,
                audioOnly: audioOnly
            )
            statusMessage = "已创建 \(pages.count) 个下载任务"
            await refreshTasks()
        } catch {
            statusMessage = friendlyErrorMessage(for: error)
        }
    }

    func refreshTasks() async {
        var coreTasks: [DownloadTaskItem] = []
        if coreState.isRunning {
            do {
                coreTasks = try await service.tasks()
            } catch {
                statusMessage = friendlyErrorMessage(for: error)
            }
        }
        publishTasks(coreTasks: coreTasks)
    }

    func pause(_ item: DownloadTaskItem) async {
        await control(item, action: .pause)
    }

    func resume(_ item: DownloadTaskItem) async {
        await control(item, action: .resume)
    }

    func delete(_ item: DownloadTaskItem) async {
        await control(item, action: .deleteAndFile)
    }

    func importCookies() async {
        let value = cookies.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            statusMessage = "Cookie 为空"
            return
        }
        await ensureCoreRunning()
        guard coreState.isRunning else { return }

        do {
            try await service.importCookies(value, accessToken: accessToken)
            savePreferences()
            await refreshUserInfo()
            statusMessage = "Cookie 已导入"
        } catch {
            statusMessage = friendlyErrorMessage(for: error)
        }
    }

    func revealDownloadDirectory() {
        NSWorkspace.shared.open(URL(fileURLWithPath: downloadDirectory, isDirectory: true))
    }

    private func control(_ item: DownloadTaskItem, action: Jijidown_Core_TaskDo) async {
        guard item.source == .jijiDownCore else { return }
        do {
            try await service.control(taskID: item.id, action: action)
            await refreshTasks()
        } catch {
            statusMessage = friendlyErrorMessage(for: error)
        }
    }

    private func ensureCoreRunning() async {
        if coreState.isRunning { return }
        await startCore()
    }

    private func waitForPing() async throws -> String {
        var lastError: Error?
        for _ in 0..<20 {
            do {
                return try await service.ping()
            } catch {
                lastError = error
                try? await _Concurrency.Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError ?? CoreError.coreMissing
    }

    private func refreshUserInfo() async {
        do {
            let user = try await service.userInfo()
            userLabel = user.isLogin ? "\(user.uname)\(user.vipStatus ? " · \(user.vipLabelText)" : "")" : "未登录"
        } catch {
            userLabel = "未登录"
        }
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        let debugDescription = String(describing: error)
        if debugDescription.contains("GetVideoList function not allowed") {
            return "JiJiDownCore 当前不允许解析视频列表，已切换到 yt-dlp 后端"
        }
        if debugDescription.contains("RPCError") {
            return "核心连接失败，请重新启动核心后再试。详情: \(debugDescription)"
        }
        return error.localizedDescription
    }

    private func shouldFallbackToYTDLP(for error: Error) -> Bool {
        let debugDescription = String(describing: error)
        return debugDescription.contains("GetVideoList function not allowed")
            || debugDescription.contains("invalid client request")
    }

    private func applyParsedVideo(_ video: ParsedVideo) {
        parsedVideo = video
        selectedPageIDs = Set(video.pages.map(\.id))
    }

    private func startYTDLPDownloads(pages: [VideoPage]) {
        savePreferences()
        guard ytDLPService.executablePath != nil else {
            statusMessage = YTDLPError.missingExecutable.localizedDescription
            return
        }

        let service = ytDLPService
        let targetDirectory = downloadDirectory
        let ffmpegPath = ffmpegPath
        let audioOnly = audioOnly
        let cookies = cookies

        for page in pages {
            let taskID = "yt-dlp-\(UUID().uuidString)"
            localTasks[taskID] = DownloadTaskItem(
                id: taskID,
                source: .ytDLP,
                title: page.title,
                status: .taskRunning,
                progress: 0,
                speed: "",
                eta: "",
                savePath: targetDirectory,
                videoBadge: audioOnly ? "" : "yt-dlp",
                audioBadge: audioOnly ? "yt-dlp 音频" : ""
            )
            publishTasks()

            Task { [weak self] in
                do {
                    try await service.download(
                        page: page,
                        downloadDirectory: targetDirectory,
                        ffmpegPath: ffmpegPath,
                        audioOnly: audioOnly,
                        cookies: cookies,
                        progress: nil
                    )
                    await MainActor.run {
                        self?.finishLocalTask(taskID, status: .taskComplete, progress: 100, message: nil)
                    }
                } catch {
                    await MainActor.run {
                        self?.finishLocalTask(
                            taskID,
                            status: .taskError,
                            progress: 0,
                            message: self?.friendlyErrorMessage(for: error) ?? error.localizedDescription
                        )
                    }
                }
            }
        }

        statusMessage = "已创建 \(pages.count) 个 yt-dlp 下载任务"
    }

    private func finishLocalTask(
        _ taskID: String,
        status: Jijidown_Core_TaskStatusType,
        progress: UInt32,
        message: String?
    ) {
        guard var item = localTasks[taskID] else { return }
        item.status = status
        item.progress = progress
        localTasks[taskID] = item
        publishTasks()
        if let message {
            statusMessage = message
        } else if status == .taskComplete {
            statusMessage = "yt-dlp 下载完成: \(item.title)"
        }
    }

    private func publishTasks(coreTasks: [DownloadTaskItem]? = nil) {
        let currentCoreTasks = coreTasks ?? tasks.filter { $0.source == .jijiDownCore }
        let currentLocalTasks = localTasks.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        tasks = currentCoreTasks + currentLocalTasks
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                guard let self else { return }
                await self.refreshTasks()
                try? await _Concurrency.Task.sleep(for: .seconds(2))
            }
        }
    }
}
