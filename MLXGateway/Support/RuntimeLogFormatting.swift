import Foundation

enum RuntimeLogLevel: String, CaseIterable {
    case error = "错误", warning = "警告", success = "成功", info = "信息", debug = "调试", plain = "其他"
}

struct RuntimeLogLine {
    let text: String
    let level: RuntimeLogLevel
}

enum RuntimeLogFormatting {
    private static let ansi = try! NSRegularExpression(pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]")
    private static let error = try! NSRegularExpression(pattern: #"(?i)\b(ERROR|CRITICAL|FATAL|Traceback|Exception)\b|失败|异常|退出码 [1-9]|HTTP [45]\d\d|\" [45]\d\d\b"#)
    private static let warning = try! NSRegularExpression(pattern: #"(?i)\b(WARN(?:ING)?|deprecated)\b|警告|超时"#)
    private static let success = try! NSRegularExpression(pattern: #"(?i)\b(HTTP 2\d\d)\b|\" 2\d\d\b|就绪|检查通过"#)
    private static let debug = try! NSRegularExpression(pattern: #"(?i)\b(DEBUG|TRACE)\b"#)
    private static let info = try! NSRegularExpression(pattern: #"(?i)\b(INFO)\b|MLX Gateway|启动|停止"#)

    static func lines(_ raw: String) -> [RuntimeLogLine] {
        let range = NSRange(raw.startIndex..., in: raw)
        let clean = ansi.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
        return clean.components(separatedBy: .newlines).map { line in
            let range = NSRange(line.startIndex..., in: line)
            let level = [(error, RuntimeLogLevel.error), (warning, .warning), (success, .success), (debug, .debug), (info, .info)]
                .first { $0.0.firstMatch(in: line, range: range) != nil }?.1 ?? .plain
            return RuntimeLogLine(text: line, level: level)
        }
    }
}
