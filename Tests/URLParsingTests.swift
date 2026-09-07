import XCTest
import WebKit
@testable import youty

// Pure-logic tests for the URL parsing the three extractors depend on. These
// functions are the most fragile surface (platforms change URL shapes), so they
// get the most coverage. The navigation fixture uses only local HTML.

@MainActor
final class TranscriptNavigationTests: XCTestCase {
    /// A late home-page callback cannot consume or fail the active video's fetch.
    func testOnlyActiveNavigationCanCompleteFetch() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let warmup = try XCTUnwrap(webView.loadHTMLString("<html>Warmup</html>", baseURL: nil))
        let video = try XCTUnwrap(webView.loadHTMLString("<html>Video</html>", baseURL: nil))
        XCTAssertFalse(TranscriptLoader.isActiveNavigation(warmup, active: video))
        XCTAssertTrue(TranscriptLoader.isActiveNavigation(video, active: video))
        XCTAssertFalse(TranscriptLoader.isActiveNavigation(nil, active: video))
        XCTAssertFalse(TranscriptLoader.isActiveNavigation(nil, active: nil))
    }
}

final class YouTubeIDTests: XCTestCase {

    func testWatchURL() {
        XCTAssertEqual(TranscriptFetcher.extractVideoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testShortLink() {
        XCTAssertEqual(TranscriptFetcher.extractVideoID(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testShorts() {
        XCTAssertEqual(TranscriptFetcher.extractVideoID(from: "https://www.youtube.com/shorts/abc123XYZ_"), "abc123XYZ_")
    }

    func testEmbed() {
        XCTAssertEqual(TranscriptFetcher.extractVideoID(from: "https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testExtraQueryParams() {
        XCTAssertEqual(TranscriptFetcher.extractVideoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLxyz&index=2"), "dQw4w9WgXcQ")
    }

    func testNoScheme() {
        XCTAssertEqual(TranscriptFetcher.extractVideoID(from: "youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testHomepageReturnsNil() {
        XCTAssertNil(TranscriptFetcher.extractVideoID(from: "https://www.youtube.com/"))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(TranscriptFetcher.extractVideoID(from: "not a url at all"))
    }

    func testRejectsForeignHostsAndUnsafeIDs() {
        XCTAssertNil(TranscriptFetcher.extractVideoID(from: "https://example.com/watch?v=abc123"))
        XCTAssertNil(TranscriptFetcher.extractVideoID(from: "https://youtu.be.evil.example/abc123"))
        XCTAssertNil(TranscriptFetcher.extractVideoID(from: "https://youtube.com/watch?v=..%2Fescape"))
        XCTAssertNil(TranscriptFetcher.extractVideoID(from: "https://youtube.com/watch?v=abc%26other"))
    }
}

final class TikTokIDTests: XCTestCase {

    func testCanonicalVideoURL() {
        let url = URL(string: "https://www.tiktok.com/@someuser/video/7212345678901234567")!
        XCTAssertEqual(TikTokExtractor.extractVideoID(from: url), "7212345678901234567")
    }

    func testMobileVURL() {
        let url = URL(string: "https://m.tiktok.com/v/7212345678901234567.html")!
        XCTAssertEqual(TikTokExtractor.extractVideoID(from: url), "7212345678901234567")
    }

    func testProfileURLReturnsNil() {
        let url = URL(string: "https://www.tiktok.com/@someuser")!
        XCTAssertNil(TikTokExtractor.extractVideoID(from: url))
    }
}

// InstagramExtractor is @MainActor (it drives a WKWebView), so its static
// helpers are main-actor-isolated; run these on the main actor.
@MainActor
final class InstagramShortcodeTests: XCTestCase {

    func testReel() {
        let url = URL(string: "https://www.instagram.com/reel/Cabc123_-/")!
        XCTAssertEqual(InstagramExtractor.extractShortcode(from: url), "Cabc123_-")
    }

    func testPost() {
        let url = URL(string: "https://www.instagram.com/p/XYZ789/")!
        XCTAssertEqual(InstagramExtractor.extractShortcode(from: url), "XYZ789")
    }

    func testTV() {
        let url = URL(string: "https://www.instagram.com/tv/AbC/")!
        XCTAssertEqual(InstagramExtractor.extractShortcode(from: url), "AbC")
    }

    func testProfileURLReturnsNil() {
        let url = URL(string: "https://www.instagram.com/someuser/")!
        XCTAssertNil(InstagramExtractor.extractShortcode(from: url))
    }
}

final class PlatformRouterTests: XCTestCase {

    func testYouTube() {
        XCTAssertEqual(PlatformRouter.platform(for: "https://www.youtube.com/watch?v=x"), .youtube)
        XCTAssertEqual(PlatformRouter.platform(for: "https://youtu.be/x"), .youtube)
    }

    func testTikTok() {
        XCTAssertEqual(PlatformRouter.platform(for: "https://www.tiktok.com/@u/video/123"), .tiktok)
    }

    func testInstagram() {
        XCTAssertEqual(PlatformRouter.platform(for: "https://www.instagram.com/reel/x/"), .instagram)
    }

    func testUnknownReturnsNil() {
        XCTAssertNil(PlatformRouter.platform(for: "https://example.com/video"))
        XCTAssertNil(PlatformRouter.platform(for: "https://www.instagram.com/someuser/"))
    }

    func testRejectsSpoofedPlatformURLs() {
        for url in [
            "https://notyoutube.com/watch?v=x",
            "https://example.com/youtube.com/watch?v=x",
            "https://example.com/?next=https://tiktok.com/@u/video/123",
            "https://instagram.com.evil.example/reel/x/",
            "file://youtube.com/watch?v=x",
            "https://user:password@youtube.com/watch?v=x"
        ] {
            XCTAssertNil(PlatformRouter.platform(for: url), url)
        }
        XCTAssertEqual(PlatformRouter.platform(for: "YOUTUBE.COM/watch?v=x"), .youtube)
    }
}
