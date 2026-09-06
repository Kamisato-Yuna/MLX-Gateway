import Foundation

/// Incremental SSE framing, including CR, LF, CRLF, split UTF-8, comments and multiline data.
struct ResponsesClientSSEParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var name = ""
    private var serverID: String?
    private var skipLF = false
    private var firstLine = true
    private var eventBytes = 0
    private var count = 0
    static let maximumEventBytes = 1024 * 1024

    mutating func append(_ byte: UInt8) throws -> ResponsesClientEvent? {
        if skipLF { skipLF = false; if byte == 10 { return nil } }
        eventBytes += 1
        guard eventBytes <= Self.maximumEventBytes else {
            throw ResponsesClientError.message("单个 SSE 事件超过 1 MiB，已断开本地接收；保留此前原始数据，服务端是否停止未知。")
        }
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            guard var text = String(data: line, encoding: .utf8) else {
                throw ResponsesClientError.message("SSE 包含无效 UTF-8；原始字节可导出。")
            }
            line.removeAll(keepingCapacity: true)
            if firstLine { firstLine = false; if text.hasPrefix("\u{FEFF}") { text.removeFirst() } }
            if text.isEmpty {
                defer { dataLines.removeAll(keepingCapacity: true); name = ""; eventBytes = 0 }
                guard !dataLines.isEmpty else { return nil }
                count += 1
                return ResponsesClientEvent(id: count, name: name.isEmpty ? "message" : name,
                                            serverID: serverID, data: dataLines.joined(separator: "\n"))
            }
            if text.hasPrefix(":") { return nil }
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            var value = parts.count > 1 ? String(parts[1]) : ""
            if value.hasPrefix(" ") { value.removeFirst() }
            switch parts[0] {
            case "data": dataLines.append(value)
            case "event": name = value
            case "id": if !value.contains("\0") { serverID = value }
            default: break // retry and future SSE fields remain available in the raw wire data.
            }
            return nil
        }
        line.append(byte)
        return nil
    }
}
