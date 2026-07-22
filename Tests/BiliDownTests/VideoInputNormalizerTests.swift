import Testing
@testable import BiliDown

struct VideoInputNormalizerTests {
    @Test func keepsFullBVIDFromURLWithQuery() {
        let input = "https://www.bilibili.com/video/BV1NwApzwEYd/?spm_id_from=example&vd_source=example-tracking-id"

        #expect(VideoInputNormalizer.normalize(input) == "https://www.bilibili.com/video/BV1NwApzwEYd")
    }

    @Test func normalizesBareBVID() {
        #expect(VideoInputNormalizer.normalize("BV1NwApzwEYd") == "https://www.bilibili.com/video/BV1NwApzwEYd")
    }

    @Test func normalizesBVIDCaseInsensitively() {
        #expect(VideoInputNormalizer.normalize("bv1NwApzwEYd") == "https://www.bilibili.com/video/bv1NwApzwEYd")
    }

    @Test func normalizesAVID() {
        #expect(VideoInputNormalizer.normalize("av123456") == "https://www.bilibili.com/video/av123456")
    }

    @Test func rejectsIncompleteURLFragment() {
        #expect(VideoInputNormalizer.normalize("/d_source=example-tracking-id") == nil)
    }
}
