import Foundation

struct AppUpdateVersion: Comparable, Equatable, Sendable {
    private let numbers: [Int]
    private let prerelease: [String]

    init(_ raw: String) throws {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("version ") { value = String(value.dropFirst(8)) }
        if value.hasPrefix("v") || value.hasPrefix("V") { value = String(value.dropFirst()) }
        let parts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let coreAndPre = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = coreAndPre[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !core.isEmpty, core.count <= 4, core.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            throw AppUpdateError.invalidVersion(raw)
        }
        numbers = core.map { Int($0)! }
        if coreAndPre.count == 2 {
            prerelease = coreAndPre[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !prerelease.isEmpty, prerelease.allSatisfy({ !$0.isEmpty }) else {
                throw AppUpdateError.invalidVersion(raw)
            }
        } else {
            prerelease = []
        }
    }

    static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = try? AppUpdateVersion(lhs), let right = try? AppUpdateVersion(rhs) else { return false }
        return left == right
    }

    static func < (lhs: AppUpdateVersion, rhs: AppUpdateVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            guard index < lhs.prerelease.count else { return true }
            guard index < rhs.prerelease.count else { return false }
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            if let leftNumber = Int(left), let rightNumber = Int(right) { return leftNumber < rightNumber }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left < right
        }
        return false
    }

    static func == (lhs: AppUpdateVersion, rhs: AppUpdateVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
