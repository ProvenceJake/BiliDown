import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 360)
                Divider()
                mainPanel
            }
        }
        .alert("BiliDown", isPresented: .constant(false)) { }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Label(model.coreState.label, systemImage: model.coreState.isRunning ? "bolt.fill" : "bolt.slash")
                .font(.headline)

            Text(model.statusMessage)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(model.userLabel)
                .foregroundStyle(.secondary)

            Button {
                Task { await model.refreshTasks() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(!model.coreState.isRunning || model.isBusy)

            if model.coreState.isRunning {
                Button {
                    model.stopCore()
                } label: {
                    Label("停止核心", systemImage: "stop.fill")
                }
            } else {
                Button {
                    Task { await model.startCore() }
                } label: {
                    Label(model.isCoreInstalled ? "启动核心" : "安装并启动", systemImage: "play.fill")
                }
                .disabled(model.isBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("链接")
                        .font(.headline)
                    TextField("https://www.bilibili.com/video/...", text: $model.inputURL)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await model.parseURL() }
                    } label: {
                        Label("解析链接", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(model.isBusy)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("下载")
                        .font(.headline)
                    HStack {
                        TextField("下载目录", text: $model.downloadDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            chooseDirectory()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("选择下载目录")
                    }
                    HStack {
                        TextField("ffmpeg 路径", text: $model.ffmpegPath)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            chooseFFmpeg()
                        } label: {
                            Image(systemName: "terminal")
                        }
                        .help("选择 ffmpeg")
                    }
                    Toggle("只下载音频", isOn: $model.audioOnly)
                    Button {
                        model.revealDownloadDirectory()
                    } label: {
                        Label("打开下载目录", systemImage: "folder.fill")
                    }
                }

                if model.parsedVideo != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("清晰度")
                            .font(.headline)
                        Picker("视频", selection: $model.selectedVideoQualityID) {
                            ForEach(model.videoQualities) { quality in
                                Text(quality.label).tag(quality.id)
                            }
                        }
                        Picker("音频", selection: $model.selectedAudioQualityID) {
                            ForEach(model.audioQualities) { quality in
                                Text(quality.label).tag(quality.id)
                            }
                        }
                        Button {
                            Task { await model.downloadSelected() }
                        } label: {
                            Label("创建下载任务", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(model.isBusy)
                    }
                }

                DisclosureGroup("Cookie 登录") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $model.cookies)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        TextField("AccessToken，可留空", text: $model.accessToken)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task { await model.importCookies() }
                        } label: {
                            Label("导入 Cookie", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(model.isBusy)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(16)
        }
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            videoSection
            Divider()
            taskSection
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        if let video = model.parsedVideo {
            HStack(alignment: .top, spacing: 16) {
                coverImage(video.coverData)
                    .frame(width: 192, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 8) {
                    Text(video.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    HStack {
                        Text(video.upName)
                        Text(video.mark)
                    }
                    .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(video.pages) { page in
                                Toggle(isOn: pageBinding(page)) {
                                    HStack {
                                        Text("P\(page.index)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(page.title)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(page.info.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView(
                "等待解析",
                systemImage: "film.stack",
                description: Text("输入哔哩哔哩链接后开始")
            )
            .frame(maxWidth: .infinity, minHeight: 210)
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("任务")
                    .font(.headline)
                Spacer()
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if model.tasks.isEmpty {
                ContentUnavailableView("暂无任务", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.tasks) {
                    TableColumn("名称") { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .lineLimit(1)
                            Text([item.videoBadge, item.audioBadge].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("状态") { item in
                        Text(item.statusLabel)
                    }
                    .width(80)
                    TableColumn("进度") { item in
                        ProgressView(value: Double(item.progress), total: 100) {
                            Text("\(item.progress)%")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .width(150)
                    TableColumn("速度") { item in
                        Text(item.speed.isEmpty ? "-" : item.speed)
                    }
                    .width(90)
                    TableColumn("操作") { item in
                        HStack(spacing: 6) {
                            Button {
                                Task { await model.pause(item) }
                            } label: {
                                Image(systemName: "pause.fill")
                            }
                            .help("暂停")
                            .disabled(!item.canPause)

                            Button {
                                Task { await model.resume(item) }
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .help("继续")
                            .disabled(!item.canResume)

                            Button {
                                Task { await model.delete(item) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("删除任务和文件")
                            .disabled(!item.canDelete)
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(110)
                }
            }
        }
        .padding(16)
    }

    private func coverImage(_ data: Data) -> some View {
        Group {
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pageBinding(_ page: VideoPage) -> Binding<Bool> {
        Binding {
            model.selectedPageIDs.contains(page.id)
        } set: { isSelected in
            if isSelected {
                model.selectedPageIDs.insert(page.id)
            } else {
                model.selectedPageIDs.remove(page.id)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.downloadDirectory = url.path
            model.savePreferences()
        }
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.ffmpegPath = url.path
            model.savePreferences()
        }
    }
}
