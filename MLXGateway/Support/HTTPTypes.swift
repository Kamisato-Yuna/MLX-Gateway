import Foundation
import Darwin

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    static func json(statusCode: Int = 200, object: [String: Any]) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            reason: HTTPResponse.reason(for: statusCode),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: JSONSupport.data(from: object)
        )
    }

    static func unsupported(_ message: String, param: String? = nil) -> HTTPResponse {
        var error: [String: Any] = [
            "message": message,
            "type": "unsupported_request_error",
            "code": "unsupported"
        ]
        if let param {
            error["param"] = param
        }
        return json(statusCode: 400, object: ["error": error])
    }

    static func error(statusCode: Int, message: String, code: String) -> HTTPResponse {
        json(statusCode: statusCode, object: [
            "error": [
                "message": message,
                "type": "gateway_error",
                "code": code
            ]
        ])
    }

    func wireData() -> Data {
        var responseHeaders = headers
        responseHeaders["Content-Length"] = "\(body.count)"
        responseHeaders["Connection"] = "close"

        var head = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        for (key, value) in responseHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 409:
            return "Conflict"
        case 413:
            return "Payload Too Large"
        case 429:
            return "Too Many Requests"
        case 404:
            return "Not Found"
        case 502:
            return "Bad Gateway"
        case 503:
            return "Service Unavailable"
        default:
            return "OK"
        }
    }
}

enum HTTPParser {
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.firstRange(of: Data([13, 10, 13, 10])) else {
            return nil
        }

        let headerData = data[..<headerEnd.lowerBound]
        guard let head = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd.upperBound
        let body = data[bodyStart...]

        return HTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: Data(body)
        )
    }
}

/// Numeric local bind addresses keep the configured listener and child URL consistent.
enum LocalEndpoint {
    static func url(host: String, port: UInt16) -> URL? {
        var parts = URLComponents()
        parts.scheme = "http"
        let connectHost = host == "0.0.0.0" ? "127.0.0.1" : (host == "::" ? "::1" : host)
        parts.host = connectHost.contains(":") ? "[\(connectHost)]" : connectHost
        parts.port = Int(port)
        return parts.url
    }

    static func checkAvailable(host: String, port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let resolvedHost = host == "localhost" ? "127.0.0.1" : host
        guard getaddrinfo(resolvedHost, String(port), &hints, &result) == 0, let info = result else {
            throw BackendError.message("主机地址需要填写本机 IPv4 / IPv6 地址或 localhost。")
        }
        defer { freeaddrinfo(info) }
        let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendError.message("无法创建服务端口。") }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        guard bind(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            throw BackendError.message("地址 \(host):\(port) 不可用或已被其他进程占用。")
        }
    }
}
