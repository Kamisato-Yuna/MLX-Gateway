import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
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
