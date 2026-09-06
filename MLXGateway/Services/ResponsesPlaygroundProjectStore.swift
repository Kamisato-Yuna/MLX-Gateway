import Foundation

struct ResponsesPlaygroundProjectStore {
    let defaults: UserDefaults
    static let key = "responsesPlayground.projects"
    static let maximumBytes = 4 * 1024 * 1024

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> [ResponsesTestProject] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return try Self.decode(data)
    }

    func save(_ projects: [ResponsesTestProject]) throws {
        defaults.set(try Self.encode(projects), forKey: Self.key)
    }

    static func decode(_ data: Data) throws -> [ResponsesTestProject] {
        guard data.count <= maximumBytes else { throw ResponsesClientError.message("项目文件超过 4 MiB 上限。") }
        let projects = try JSONDecoder().decode([ResponsesTestProject].self, from: data)
        guard projects.count <= 100 else { throw ResponsesClientError.message("最多保存 100 个项目。") }
        guard Set(projects.map(\.id)).count == projects.count else { throw ResponsesClientError.message("导入文件中有重复项目 ID。") }
        for project in projects {
            guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ResponsesClientError.message("项目名称不能为空。")
            }
            _ = try ResponsesTestJSON.object(project.body)
        }
        return projects
    }

    static func encode(_ projects: [ResponsesTestProject]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(projects)
        _ = try decode(data)
        return data
    }
}
