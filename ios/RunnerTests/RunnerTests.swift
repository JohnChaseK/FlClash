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
}
