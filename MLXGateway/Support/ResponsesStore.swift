import Foundation
import Network

/// Process-local Responses storage. This intentionally does not write prompts to disk.
/// All access is confined to GatewayServer.queue; finished records expire or are evicted.
final class ResponsesStore {
    static let capacity = 64
    private(set) var records: [String: ResponseRecord] = [:]
    func insert(_ record: ResponseRecord) throws {
        prune()
        if records.count >= Self.capacity,
           let oldest = records.values.filter({ $0.finished }).min(by: { $0.created < $1.created }) { records.removeValue(forKey: oldest.id) }
        guard records.count < Self.capacity else {
            throw ResponsesAdapter.InvalidRequest(response: .error(statusCode: 429, message: "Too many active local responses. Cancel a response or retry later.", code: "capacity_exceeded"))
        }
        records[record.id] = record
    }
    func lookup(_ id: String) -> ResponseRecord? {
        prune()
        guard let record = records[id], record.stored || record.background else { return nil }
        return record
    }
    func remove(_ id: String) { records.removeValue(forKey: id) }
    func prune() {
        let now = Date()
        records = records.filter { _, record in
            !record.finished || (record.stored || record.background) && now.timeIntervalSince(record.finishedAt ?? record.created) < (record.stored ? 86_400 : 600)
        }
    }
}

final class ResponseRecord: @unchecked Sendable {
    let id: String
    let created = Date()
    let request: [String: Any]
    let chatData: Data
    let inputItems: [[String: Any]]
    let metricID: UUID
    let background: Bool
    let stored: Bool
    let streaming: Bool
    var response: [String: Any]
    var mapper: ResponsesStream?
    var cancellation: BackendRequestCancellation?
    var finished = false
    var finishedAt: Date?
    var events: [Data] = []
    var eventBytes = 0
    var subscribers: [ObjectIdentifier: SSEConnection] = [:]
    var connection: NWConnection?
    init(prepared: ResponsesAdapter.Prepared, metricID: UUID) {
        id = ResponsesAdapter.identifier("resp_")
        request = prepared.request; chatData = JSONSupport.data(from: prepared.chat); inputItems = prepared.inputItems
        self.metricID = metricID
        background = request["background"] as? Bool == true; stored = request["store"] as? Bool == true
        streaming = request["stream"] as? Bool == true
        response = ResponsesAdapter.skeleton(request: request, id: id, status: background ? "queued" : "in_progress")
        if streaming { mapper = ResponsesStream(request: request, response: response) }
    }
}

/// A bounded send queue applies backpressure to slow clients instead of buffering the
/// entire generation. NWConnection and this writer are both used on the gateway queue.
final class SSEConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let disconnected: @Sendable () -> Void
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var sending = false
    private var ending = false
    private var closed = false
    init(connection: NWConnection, queue: DispatchQueue, disconnected: @escaping @Sendable () -> Void) {
        self.connection = connection; self.queue = queue; self.disconnected = disconnected
        append(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nX-Accel-Buffering: no\r\nConnection: close\r\n\r\n".utf8))
    }
    func append(_ data: Data) {
        guard !closed, !ending else { return }
        pendingBytes += data.count
        guard pendingBytes <= 16 * 1024 * 1024 else { close(); return }
        pending.append(data); pump()
    }
    func finish() { ending = true; pump() }
    private func close() {
        guard !closed else { return }
        closed = true; pending.removeAll(); connection.cancel(); disconnected()
    }
    private func pump() {
        guard !closed, !sending else { return }
        guard !pending.isEmpty else { if ending { close() }; return }
        let data = pending.removeFirst(); sending = true
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sending = false; self.pendingBytes -= data.count
                if error != nil { self.close() } else { self.pump() }
            }
        })
    }
}
