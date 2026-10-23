import XCTest
import RibbonCore
@testable import RibbonAX

final class FrameWriteMailboxTests: XCTestCase {
    func testThousandGestureFramesNeedOnlyOneWaitingJobAndKeepLatestFrame() throws {
        let mailbox = FrameWriteMailbox()
        var jobs: [UInt64] = []
        for x in 0..<1_000 {
            let write = FrameWrite(position: CGPoint(x: x, y: 42), size: CGSize(width: 800 + x, height: 600))
            if let token = mailbox.submit(write, for: 1) { jobs.append(token) }
        }
        XCTAssertEqual(jobs.count, 1)
        let write = try XCTUnwrap(mailbox.take(for: 1, token: jobs[0]))
        XCTAssertEqual(write.position, CGPoint(x: 999, y: 42))
        XCTAssertEqual(write.size, CGSize(width: 1_799, height: 600))
        XCTAssertNil(mailbox.take(for: 1, token: jobs[0]))
    }

    func testAnimationPositionsPreservePendingResize() throws {
        let mailbox = FrameWriteMailbox()
        let size = CGSize(width: 900, height: 600)
        let token = try XCTUnwrap(mailbox.submit(FrameWrite(position: nil, size: size), for: 1))
        XCTAssertNil(mailbox.submit(FrameWrite(position: CGPoint(x: 300, y: 20), size: nil), for: 1))
        XCTAssertEqual(mailbox.take(for: 1, token: token), FrameWrite(position: CGPoint(x: 300, y: 20), size: size))
    }

    func testFullFrameThenNewPositionCannotBeReorderedByOldPositionConsumer() throws {
        let mailbox = FrameWriteMailbox()
        let token = try XCTUnwrap(mailbox.submit(FrameWrite(position: .zero, size: nil), for: 1))
        let size = CGSize(width: 900, height: 600)
        XCTAssertNil(mailbox.submit(FrameWrite(position: CGPoint(x: 100, y: 20), size: size), for: 1))
        XCTAssertNil(mailbox.submit(FrameWrite(position: CGPoint(x: 200, y: 20), size: nil), for: 1))
        XCTAssertEqual(mailbox.take(for: 1, token: token), FrameWrite(position: CGPoint(x: 200, y: 20), size: size))
    }

    func testForcedFinalSizeIsRetainedWhenFollowedBySameSizeMove() throws {
        let mailbox = FrameWriteMailbox()
        let size = CGSize(width: 900, height: 600)
        let token = try XCTUnwrap(mailbox.submit(FrameWrite(position: CGPoint(x: 100, y: 20), size: nil), for: 1))
        XCTAssertNil(mailbox.submit(FrameWrite(position: CGPoint(x: 200, y: 20), size: size), for: 1))
        XCTAssertNil(mailbox.submit(FrameWrite(position: CGPoint(x: 300, y: 20), size: nil), for: 1))
        XCTAssertEqual(mailbox.take(for: 1, token: token), FrameWrite(position: CGPoint(x: 300, y: 20), size: size))
    }

    func testNewFrameAfterConsumerStartedQueuesOneMoreJob() throws {
        let mailbox = FrameWriteMailbox()
        let first = FrameWrite(position: .zero, size: CGSize(width: 800, height: 600))
        let firstToken = try XCTUnwrap(mailbox.submit(first, for: 1))
        XCTAssertEqual(mailbox.take(for: 1, token: firstToken), first)
        let secondToken = try XCTUnwrap(mailbox.submit(FrameWrite(position: CGPoint(x: 10, y: 20), size: nil), for: 1))
        XCTAssertNotEqual(firstToken, secondToken)
        for x in 11...1_000 {
            XCTAssertNil(mailbox.submit(FrameWrite(position: CGPoint(x: x, y: 20), size: nil), for: 1))
        }
        XCTAssertEqual(mailbox.take(for: 1, token: secondToken)?.position, CGPoint(x: 1_000, y: 20))
    }

    func testForgottenWindowCannotConsumeReusedIDsWrite() throws {
        let mailbox = FrameWriteMailbox()
        let oldToken = try XCTUnwrap(mailbox.submit(FrameWrite(position: .zero, size: nil), for: 1))
        mailbox.remove(1)
        let replacement = FrameWrite(position: CGPoint(x: 50, y: 50), size: CGSize(width: 400, height: 300))
        let newToken = try XCTUnwrap(mailbox.submit(replacement, for: 1))
        XCTAssertNil(mailbox.take(for: 1, token: oldToken))
        XCTAssertEqual(mailbox.take(for: 1, token: newToken), replacement)
    }

    func testWindowsHaveIndependentMailboxes() throws {
        let mailbox = FrameWriteMailbox()
        let first = FrameWrite(position: CGPoint(x: 10, y: 20), size: nil)
        let second = FrameWrite(position: CGPoint(x: 30, y: 40), size: nil)
        let firstToken = try XCTUnwrap(mailbox.submit(first, for: 1))
        let secondToken = try XCTUnwrap(mailbox.submit(second, for: 2))
        mailbox.remove(1)
        XCTAssertNil(mailbox.take(for: 1, token: firstToken))
        XCTAssertEqual(mailbox.take(for: 2, token: secondToken), second)
    }
}
