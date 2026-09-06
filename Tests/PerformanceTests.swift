import Foundation
import Darwin

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    func read() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

@main
enum PerformanceTests {
    @MainActor
    static func main() async throws {
        let clock = TestClock()
        let store = RequestMetricsStore(capacity: 2, clock: { clock.read() })
        let first = store.begin(modelID: "model-a")
        clock.advance(1)
        store.firstToken(first)
        clock.advance(2)
        store.firstToken(first)
        store.finish(first, statusCode: 200, inputTokens: 10, outputTokens: 6)
        store.finish(first, statusCode: 500)
        let initial = store.snapshot()
        precondition(initial.inFlight == 0 && initial.records.count == 1)
        precondition(initial.records[0].duration == 3 && initial.records[0].firstTokenLatency == 1)
        precondition(initial.records[0].outputTokensPerSecond == 2)

        let second = store.begin(modelID: "model-a")
        clock.advance(10)
        store.finish(second, statusCode: 502, inputTokens: -1, outputTokens: -1, error: "downstream_error")
        precondition(store.snapshot().records[1].firstTokenLatency == nil)
        precondition(store.snapshot().records[1].outputTokens == nil)
        let summary = PerformanceSummary(records: store.snapshot().records)
        precondition(summary.failureCount == 1 && summary.average == 3 && summary.percentile(0.95) == 3)
        let third = store.begin(modelID: "model-b")
        store.clearCompleted()
        precondition(store.snapshot().inFlight == 1)
        store.finish(third, statusCode: 200)
        for _ in 0..<3 { store.finish(store.begin(modelID: "model-c"), statusCode: 200) }
        precondition(store.snapshot().records.count == 2)

        let concurrent = RequestMetricsStore(capacity: 500)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            let id = concurrent.begin(modelID: "test")
            concurrent.firstToken(id)
            concurrent.finish(id, statusCode: 200)
            concurrent.finish(id, statusCode: 499)
        }
        precondition(concurrent.snapshot().records.count == 500 && concurrent.snapshot().inFlight == 0)

        func reading(_ pid: Int32 = 4, _ start: UInt64 = 1, _ time: Double, _ cpu: UInt64) -> ProcessResourceReading {
            ProcessResourceReading(pid: pid, startedAt: start, sampledAt: time, cpuNanoseconds: cpu,
                residentBytes: 0, footprintBytes: 0, readBytes: 0, writtenBytes: 0)
        }
        precondition(ProcessResourceSampler.cpuPercent(current: reading(4, 1, 2, 3_000_000_000), previous: reading(4, 1, 0, 0)) == 150)
        precondition(ProcessResourceSampler.cpuPercent(current: reading(4, 2, 2, 3), previous: reading(4, 1, 0, 0)) == nil)
        precondition(ProcessResourceSampler.cpuPercent(current: reading(5, 1, 2, 3), previous: reading(4, 1, 0, 0)) == nil)
        precondition(ProcessResourceSampler.read(pid: -1) == nil)
        guard let current = ProcessResourceSampler.read(pid: getpid()) else { fatalError("Cannot sample the test process") }
        precondition(current.residentBytes > 0 && current.footprintBytes > 0)
        let monitor = PerformanceMonitor()
        monitor.interval = 1
        monitor.refresh(pid: getpid(), modelID: "test-process")
        try await Task.sleep(for: .milliseconds(2200))
        precondition(monitor.samples.count >= 2, "Resource sampling must continue independently of log refresh")
        monitor.enabled = false
        let pausedCount = monitor.samples.count
        try await Task.sleep(for: .milliseconds(1100))
        precondition(monitor.samples.count == pausedCount)
        monitor.stop()
        print("PASS: request timing, idempotent finish, bounded concurrent history, percentiles, PID reuse, live resources and independent sampling timer")
    }
}
