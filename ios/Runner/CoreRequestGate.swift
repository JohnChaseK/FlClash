import Foundation

@MainActor
final class CoreRequestGate {
    typealias Operation = (@escaping () -> Void) -> Void

    private var readers = 0
    private var barrierRunning = false
    private var waiting: [(barrier: Bool, operation: Operation)] = []

    func request(_ operation: @escaping Operation) {
        waiting.append((false, operation))
        drain()
    }

    func barrier(_ operation: @escaping Operation) {
        waiting.append((true, operation))
        drain()
    }

    private func drain() {
        guard !barrierRunning else { return }
        while !barrierRunning, let first = waiting.first {
            if first.barrier {
                guard readers == 0 else { return }
                waiting.removeFirst()
                barrierRunning = true
                first.operation { [self] in
                    barrierRunning = false
                    drain()
                }
                return
            }
            waiting.removeFirst()
            readers += 1
            first.operation { [self] in
                readers -= 1
                drain()
            }
        }
    }
}
