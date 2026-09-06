import Foundation

struct RequestMetric: Identifiable, Sendable, Codable, Equatable {
    let id: UUID
    let modelID: String
    let startedAt: Date
    let duration: Double
    let firstTokenLatency: Double?
    let statusCode: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let error: String?

    var succeeded: Bool { (200..<300).contains(statusCode) && error == nil }
    /// End-to-end throughput includes prompt processing; it is not decode-only speed.
    var outputTokensPerSecond: Double? {
        guard succeeded, let outputTokens, duration > 0 else { return nil }
        return Double(outputTokens) / duration
    }
}

/// Only metadata is retained. Prompts, generated text, headers and model paths are never recorded.
final class RequestMetricsStore: @unchecked Sendable {
    static let shared = RequestMetricsStore()
    private struct Pending {
        let modelID: String
        let date: Date
        let start: Double
        var firstToken: Double?
    }
    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var completed: [RequestMetric] = []
    private let capacity: Int
    private let clock: @Sendable () -> Double

    init(capacity: Int = 500, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = max(1, capacity)
        self.clock = clock
    }

    func begin(modelID: String) -> UUID {
        lock.withLock {
            let id = UUID()
            pending[id] = Pending(modelID: modelID, date: Date(), start: clock())
            return id
        }
    }

    func firstToken(_ id: UUID) {
        lock.withLock {
            guard var value = pending[id], value.firstToken == nil else { return }
            value.firstToken = max(0, clock() - value.start)
            pending[id] = value
        }
    }

    func finish(_ id: UUID, statusCode: Int, inputTokens: Int? = nil, outputTokens: Int? = nil, error: String? = nil) {
        lock.withLock {
            guard let value = pending.removeValue(forKey: id) else { return }
            completed.append(RequestMetric(id: id, modelID: value.modelID, startedAt: value.date,
                duration: max(0, clock() - value.start), firstTokenLatency: value.firstToken,
                statusCode: statusCode, inputTokens: inputTokens.flatMap { $0 >= 0 ? $0 : nil },
                outputTokens: outputTokens.flatMap { $0 >= 0 ? $0 : nil }, error: error))
            if completed.count > capacity { completed.removeFirst(completed.count - capacity) }
        }
    }

    func snapshot() -> (records: [RequestMetric], inFlight: Int) {
        lock.withLock { (completed, pending.count) }
    }

    func clearCompleted() { lock.withLock { completed.removeAll() } }
}

struct PerformanceSummary {
    let records: [RequestMetric]
    var successCount: Int { records.filter(\.succeeded).count }
    var failureCount: Int { records.count - successCount }
    var successfulDurations: [Double] { records.filter(\.succeeded).map(\.duration).sorted() }
    var average: Double? {
        let values = successfulDurations
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    func percentile(_ fraction: Double) -> Double? {
        let values = successfulDurations
        guard !values.isEmpty else { return nil }
        let index = max(0, min(values.count - 1, Int(ceil(Double(values.count) * min(1, max(0, fraction)))) - 1))
        return values[index]
    }
}
