import Foundation

enum JSONSupport {
    static func object(from data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func data(from object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    static func boolValue(_ value: Any?) -> Bool {
        (value as? Bool) == true
    }
}
