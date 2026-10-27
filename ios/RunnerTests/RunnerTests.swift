import XCTest

@testable import Runner

@MainActor
final class RunnerTests: XCTestCase {
    func testHandoffWaitsForAllInFlightCalls() {
        let gate = CoreRequestGate()
        var completions: [() -> Void] = []
        var events: [String] = []
        gate.request { done in
            events.append("first")
            completions.append(done)
        }
        gate.request { done in
            events.append("second")
            completions.append(done)
        }
        gate.barrier { done in
            events.append("handoff")
            done()
        }
        XCTAssertEqual(events, ["first", "second"])
        completions[1]()
        XCTAssertEqual(events, ["first", "second"])
        completions[0]()
        XCTAssertEqual(events, ["first", "second", "handoff"])
    }

    func testCallsArrivingDuringHandoffKeepTheirOrder() {
        let gate = CoreRequestGate()
        var finish: (() -> Void)?
        var events: [String] = []
        gate.barrier { done in finish = done }
        gate.request { done in
            events.append("first")
            done()
        }
        gate.request { done in
            events.append("second")
            done()
        }
        XCTAssertTrue(events.isEmpty)
        finish?()
        XCTAssertEqual(events, ["first", "second"])
    }

    func testStopCannotOvertakeAnActiveStart() {
        let gate = CoreRequestGate()
        var finishStart: (() -> Void)?
        var events: [String] = []
        gate.barrier { done in
            events.append("start")
            finishStart = done
        }
        gate.barrier { done in
            events.append("stop")
            done()
        }
        gate.request { done in
            events.append("call")
            done()
        }
        XCTAssertEqual(events, ["start"])
        finishStart?()
        XCTAssertEqual(events, ["start", "stop", "call"])
    }

    func testSynchronousCompletionCannotDrainPastANestedBarrier() {
        let gate = CoreRequestGate()
        var finishHandoff: (() -> Void)?
        var events: [String] = []
        gate.request { done in
            gate.barrier { finish in
                events.append("handoff")
                finishHandoff = finish
            }
            gate.request { finish in
                events.append("call")
                finish()
            }
            done()
        }
        XCTAssertEqual(events, ["handoff"])
        finishHandoff?()
        XCTAssertEqual(events, ["handoff", "call"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func capture(_ text: String, in directory: URL) throws -> TunnelSnapshot {
        try Data(text.utf8).write(to: directory.appendingPathComponent("config.yaml"))
        return try TunnelSnapshot.capture(
            initialization: JSONSerialization.data(withJSONObject: ["home-dir": directory.path]),
            setup: JSONSerialization.data(withJSONObject: [
                "base": ["path": "/deleted-profile.yaml", "overlay": "rules: []"],
                "selected-map": ["Proxy": "Node"],
            ]), options: Data("{}".utf8))
    }

    func testIndependentStartRestoresLastSuccessfulYAML() throws {
        let directory = try temporaryDirectory()
        try TunnelStorage.save(capture("rules: [MATCH,DIRECT]", in: directory), directory: directory)
        let latest = try capture("rules: [MATCH,REJECT]", in: directory)
        try TunnelStorage.save(latest, directory: directory)
        try Data("invalid later edit".utf8).write(to: directory.appendingPathComponent("config.yaml"))

        let snapshot = try TunnelStorage.load(directory: directory)
        try snapshot.restoreConfiguration()

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("config.yaml")), latest.configuration)
        let setup = try JSONSerialization.jsonObject(with: snapshot.setup) as! [String: Any]
        XCTAssertNil(setup["base"])
        XCTAssertEqual(setup["selected-map"] as? [String: String], ["Proxy": "Node"])
    }

    func testFailedCapturePreservesCommittedSnapshot() throws {
        let directory = try temporaryDirectory()
        let snapshot = try capture("rules: [MATCH,DIRECT]", in: directory)
        try TunnelStorage.save(snapshot, directory: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("config.yaml"))

        XCTAssertThrowsError(try TunnelSnapshot.capture(
            initialization: snapshot.initialization, setup: snapshot.setup, options: snapshot.options))

        XCTAssertEqual(try TunnelStorage.load(directory: directory).configuration, snapshot.configuration)
    }

    func testSnapshotRetainsLivePatchesAndTunnelOptions() throws {
        let directory = try temporaryDirectory()
        var snapshot = try capture("rules: []", in: directory)
        snapshot.update = Data("{\"mode\":\"global\"}".utf8)
        snapshot.options = Data("{\"ipv6\":true}".utf8)
        try TunnelStorage.save(snapshot, directory: directory)

        let reopened = try TunnelStorage.load(directory: directory)

        XCTAssertEqual(reopened.update, snapshot.update)
        XCTAssertEqual(reopened.options, snapshot.options)
    }

    func testOldSnapshotWithoutEmbeddedConfigurationCanStillBeRead() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "initialization": Data("{}".utf8).base64EncodedString(),
            "setup": Data("{}".utf8).base64EncodedString(),
            "options": Data("{}".utf8).base64EncodedString(),
        ])
        let snapshot = try JSONDecoder().decode(TunnelSnapshot.self, from: data)

        XCTAssertNil(snapshot.configuration)
        XCTAssertNil(snapshot.update)
    }

    func testCoreLeaseExcludesAnotherOwnerUntilShutdownReleasesIt() async throws {
        let directory = try temporaryDirectory()
        var owner: CoreLease? = try await CoreLease.acquire(directory: directory)
        do {
            _ = try await CoreLease.acquire(directory: directory, timeout: 0)
            XCTFail("Two Core owners acquired the same directory")
        } catch {
            XCTAssertNotNil(owner)
        }
        owner = nil

        let successor = try await CoreLease.acquire(directory: directory, timeout: 0)

        withExtendedLifetime(successor) {}
    }

    func testCoreHandoffWaitsForTheExistingOwner() async throws {
        let directory = try temporaryDirectory()
        var owner: CoreLease? = try await CoreLease.acquire(directory: directory)
        let successor = Task { try await CoreLease.acquire(directory: directory, timeout: 1) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(owner)
        owner = nil

        let acquired = try await successor.value

        withExtendedLifetime(acquired) {}
    }
}
