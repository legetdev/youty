import XCTest
@testable import youty

// A stale visitor ID must never block transcripts. YouTube rejects one with a
// 200 and LOGIN_REQUIRED ("Sign in to confirm you're not a bot"), which the
// player API parses as a restricted video, not with 401/403.

final class VisitorDataTests: XCTestCase {

    private var saved: (String?, Any?)

    override func setUp() {
        saved = (UserDefaults.standard.string(forKey: "youtubeVisitorData"),
                 UserDefaults.standard.object(forKey: "youtubeVisitorDataTimestamp"))
        StreamFetcher.invalidateVisitorData()
    }

    override func tearDown() {
        StreamFetcher.invalidateVisitorData()
        if let id = saved.0 { UserDefaults.standard.set(id, forKey: "youtubeVisitorData") }
        if let ts = saved.1 { UserDefaults.standard.set(ts, forKey: "youtubeVisitorDataTimestamp") }
    }

    func testStaleCachedIDHittingTheBotCheckIsRefreshedOnce() async throws {
        StreamFetcher.cacheVisitorData("stale")
        var fetches = 0, attempts: [String] = []
        let result = try await StreamFetcher.withVisitorData(fetchFresh: { fetches += 1; return "fresh" }) { id in
            attempts.append(id)
            if id == "stale" { throw StreamFetchError.restrictedVideo }
            return id
        }
        XCTAssertEqual(result, "fresh")
        XCTAssertEqual(attempts, ["stale", "fresh"])
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(StreamFetcher.cachedVisitorData(), "fresh")
    }

    func testRejectedCachedIDIsRefreshed() async throws {
        StreamFetcher.cacheVisitorData("stale")
        let result = try await StreamFetcher.withVisitorData(fetchFresh: { "fresh" }) { id in
            if id == "stale" { throw StreamFetchError.visitorDataInvalid }
            return id
        }
        XCTAssertEqual(result, "fresh")
    }

    func testRestrictedVideoWithAFreshIDIsNotRetried() async {
        var fetches = 0, attempts = 0
        do {
            _ = try await StreamFetcher.withVisitorData(fetchFresh: { fetches += 1; return "fresh" }) { (_: String) -> Int in
                attempts += 1
                throw StreamFetchError.restrictedVideo
            }
            XCTFail("a genuinely restricted video must still fail")
        } catch StreamFetchError.restrictedVideo {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(attempts, 1)
    }

    func testWorkingCachedIDIsKept() async throws {
        StreamFetcher.cacheVisitorData("good")
        var fetches = 0
        let result = try await StreamFetcher.withVisitorData(fetchFresh: { fetches += 1; return "fresh" }) { $0 }
        XCTAssertEqual(result, "good")
        XCTAssertEqual(fetches, 0)
    }
}
