import Foundation
import Testing
@testable import BiliDown

struct CoreIntegrationTests {
    @Test func parsesURLThroughAvailableBackendWhenRequested() async throws {
        guard let input = ProcessInfo.processInfo.environment["BILIDOWN_INTEGRATION_URL"],
              let url = VideoInputNormalizer.normalize(input) else {
            return
        }

        let coreManager = CoreManager()
        let ffmpegPath = await coreManager.findFFmpeg() ?? "/opt/homebrew/bin/ffmpeg"
        let downloadDirectory = await coreManager.defaultDownloadDirectoryURL.path

        try await coreManager.start(downloadDirectory: downloadDirectory, ffmpegPath: ffmpegPath)
        let service = JiJiDownService()

        do {
            var pingSucceeded = false
            for _ in 0..<20 {
                do {
                    _ = try await service.ping()
                    pingSucceeded = true
                    break
                } catch {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            #expect(pingSucceeded)

            let parsed: ParsedVideo
            do {
                parsed = try await service.parseVideo(url)
            } catch {
                guard String(describing: error).contains("GetVideoList function not allowed") else {
                    throw error
                }
                parsed = try await YTDLPService().parse(url)
            }

            #expect(!parsed.title.isEmpty)
            #expect(!parsed.pages.isEmpty)
            print("PARSED_TITLE=\(parsed.title)")
            print("PARSED_PAGES=\(parsed.pages.count)")
            print("PARSED_SOURCE=\(parsed.source)")
        } catch {
            await coreManager.stop()
            throw error
        }

        await coreManager.stop()
    }
}
