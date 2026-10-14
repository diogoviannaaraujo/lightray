import Foundation
import XCTest
@testable import lightray_client

@MainActor
final class HostServiceTests: XCTestCase {
    private func fixture(_ script: String) throws -> (URL, HostService) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let helper = directory.appendingPathComponent("helper")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (directory, HostService(executable: helper, logURL: directory.appendingPathComponent("host.log")))
    }

    func testReadinessStopAndRestart() async throws {
        let (directory, service) = try fixture("""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--ready-file" ]; then shift; ready="$1"; fi
                shift
            done
            trap 'exit 0' TERM
            sleep 0.2
            printf 'ready\n' > "$ready"
            while :; do sleep 0.1; done
            """)
        defer { service.stop(); try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<2 {
            service.start(port: 17373, quality: .balanced, allowInput: false)
            XCTAssertEqual(service.state, .starting)
            XCTAssertTrue(service.isActive)
            try await waitUntil { service.state == .running }
            var stopped = false
            service.stop { stopped = true }
            try await waitUntil { stopped }
            XCTAssertEqual(service.state, .stopped)
            XCTAssertFalse(service.isActive)
        }
    }

    func testFailedHelperShowsItsErrorAndCanRetry() async throws {
        let (directory, service) = try fixture("echo 'bind: Address already in use'\nexit 12\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<2 {
            service.start(port: 7373, quality: .smooth, allowInput: true)
            try await waitUntil { !service.isActive }
            guard case .failed(let message) = service.state else { XCTFail("Expected failure"); return }
            XCTAssertTrue(message.contains("12"))
            XCTAssertTrue(message.contains("Address already in use"))
        }
    }

    func testMissingHelperDoesNotRemainStarting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HostService(executable: directory.appendingPathComponent("missing"),
                                  logURL: directory.appendingPathComponent("host.log"))
        service.start(port: 7373, quality: .balanced, allowInput: false)
        XCTAssertFalse(service.isActive)
        guard case .failed = service.state else { XCTFail("Expected failure"); return }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { XCTFail("Timed out"); throw Timeout.expired }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum Timeout: Error { case expired }
}
