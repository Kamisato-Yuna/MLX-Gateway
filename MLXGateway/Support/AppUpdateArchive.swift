import Darwin
import Foundation

/// Reads only ZIP regular files/directories. No extraction is delegated to an external tool.
/// The budget is charged against bytes returned by the decoder, never ZIP size declarations.
enum AppUpdateArchive {
    static let maximumArchiveBytes: Int64 = 1_073_741_824
    static let maximumExpandedBytes: Int64 = 2_147_483_648

    static func extract(_ archive: URL, to root: URL, maximumBytes: Int64 = maximumExpandedBytes,
                        checkCancellation: () throws -> Void = {}) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        try validateDirectory(input)
        try input.seek(toOffset: 0)
        let library = try ArchiveLibrary()
        guard let reader = library.readNew() else { throw AppUpdateError.invalidArchive("无法创建 ZIP 解码器。") }
        defer { _ = library.readFree(reader) }
        guard library.supportZIP(reader) == 0,
              "zip:!mac-ext".withCString({ library.setOptions(reader, $0) }) == 0,
              library.openFD(reader, input.fileDescriptor, 65_536) == 0 else {
            throw AppUpdateError.invalidArchive(library.error(reader))
        }
        var entry: OpaquePointer?
        var total: Int64 = 0
        var count = 0
        var metadataFiles: [URL] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try checkCancellation()
            let result = library.nextHeader(reader, &entry)
            if result == 1 { break } // ARCHIVE_EOF
            guard result == 0, let entry else { throw AppUpdateError.invalidArchive(library.error(reader)) }
            count += 1
            guard count <= 100_000, let name = library.pathname(entry),
                  let path = String(validatingCString: name) else {
                throw AppUpdateError.invalidArchive("ZIP 条目过多或文件名编码无效。")
            }
            try AppUpdateArchiveValidator.validateEntry(path)
            let kind = library.filetype(entry)
            guard library.symlink(entry) == nil, library.hardlink(entry) == nil,
                  kind == UInt32(S_IFREG) || kind == UInt32(S_IFDIR) else {
                throw AppUpdateError.invalidArchive("压缩包包含链接或特殊文件。")
            }
            // Foundation normalizes dots; rejecting them also prevents aliases and duplicate writes.
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !parts.isEmpty, !parts.contains(".") else {
                throw AppUpdateError.invalidArchive("ZIP 包含空路径或路径别名。")
            }
            let output = root.appendingPathComponent(parts.joined(separator: "/"))
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            if kind == UInt32(S_IFDIR) {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: output.path, isDirectory: &directory) {
                    guard directory.boolValue else { throw AppUpdateError.invalidArchive("ZIP 路径类型冲突。") }
                } else {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                }
                continue
            }
            let fd = output.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            guard fd >= 0 else { throw AppUpdateError.invalidArchive("ZIP 包含重复条目或无法创建文件。") }
            do {
                while true {
                    try checkCancellation()
                    let bytes = buffer.withUnsafeMutableBytes { library.readData(reader, $0.baseAddress!, $0.count) }
                    guard bytes >= 0 else { throw AppUpdateError.invalidArchive(library.error(reader)) }
                    if bytes == 0 { break }
                    guard Int64(bytes) <= maximumBytes - total else {
                        throw AppUpdateError.invalidArchive("实际解压内容超过允许大小。")
                    }
                    total += Int64(bytes)
                    try buffer.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < bytes {
                            let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes - offset)
                            if written < 0 && errno == EINTR { continue }
                            guard written > 0 else { throw AppUpdateError.invalidArchive("无法写入解压内容，可能磁盘空间不足。") }
                            offset += written
                        }
                    }
                }
                // Preserve execute bits, but never setuid/setgid/sticky or write permission for other users.
                guard fchmod(fd, mode_t(library.permissions(entry)) & 0o755 | 0o600) == 0 else {
                    throw AppUpdateError.invalidArchive("无法设置文件权限。")
                }
                Darwin.close(fd)
                if parts.first == "__MACOSX", output.lastPathComponent.hasPrefix("._") { metadataFiles.append(output) }
            } catch {
                Darwin.close(fd)
                throw error
            }
        }
        guard count > 0 else { throw AppUpdateError.invalidArchive("ZIP 为空。") }
        try restoreMetadata(in: root, files: metadataFiles)
    }

    private static func validateDirectory(_ input: FileHandle) throws {
        // libarchive normalizes some Unix special-file modes into regular files. Check the original
        // central-directory type bits as well; expansion limits below still use decoded bytes.
        let length = try input.seekToEnd()
        guard length >= 22, length <= UInt64(maximumArchiveBytes) else {
            throw AppUpdateError.invalidArchive("ZIP 大小无效或超过 1 GiB。")
        }
        let tailSize = min(length, 65_557)
        try input.seek(toOffset: length - tailSize)
        let tail = try input.read(upToCount: Int(tailSize)) ?? Data()
        func u16(_ data: Data, _ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
        }
        guard tail.count >= 22, let end = (0...(tail.count - 22)).reversed().first(where: {
            u32(tail, $0) == 0x06054b50 && $0 + 22 + Int(u16(tail, $0 + 20)) == tail.count
        }) else { throw AppUpdateError.invalidArchive("ZIP 目录结束记录无效。") }
        let count = Int(u16(tail, end + 10))
        let directorySize = UInt64(u32(tail, end + 12)), directoryOffset = UInt64(u32(tail, end + 16))
        guard u16(tail, end + 4) == 0, u16(tail, end + 6) == 0,
              Int(u16(tail, end + 8)) == count, count > 0, count < 65_535,
              directoryOffset + directorySize <= length - tailSize + UInt64(end) else {
            throw AppUpdateError.invalidArchive("不支持分卷或 ZIP64 目录。")
        }
        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= directoryOffset + directorySize else { throw AppUpdateError.invalidArchive("ZIP 目录截断。") }
            try input.seek(toOffset: cursor)
            guard let header = try input.read(upToCount: 46), header.count == 46, u32(header, 0) == 0x02014b50 else {
                throw AppUpdateError.invalidArchive("ZIP 中央目录无效。")
            }
            let mode = (u32(header, 38) >> 16) & UInt32(S_IFMT)
            guard mode == 0 || mode == UInt32(S_IFREG) || mode == UInt32(S_IFDIR) else {
                throw AppUpdateError.invalidArchive("ZIP 中央目录包含链接或特殊文件。")
            }
            let nameLength = Int(u16(header, 28))
            let recordSize = UInt64(46 + nameLength + Int(u16(header, 30)) + Int(u16(header, 32)))
            guard cursor + recordSize <= directoryOffset + directorySize,
                  let name = try input.read(upToCount: nameLength), name.count == nameLength,
                  !name.contains(0), let path = String(data: name, encoding: .utf8) else {
                throw AppUpdateError.invalidArchive("ZIP 文件名无效。")
            }
            try AppUpdateArchiveValidator.validateEntry(path)
            cursor += recordSize
        }
        guard cursor == directoryOffset + directorySize else { throw AppUpdateError.invalidArchive("ZIP 目录长度不匹配。") }
    }

    private static func restoreMetadata(in root: URL, files: [URL]) throws {
        // Decode AppleDouble only after its bytes have passed through the same expansion budget.
        // This preserves notarization tickets and resource forks from ditto --sequesterRsrc ZIPs.
        let metadata = root.appendingPathComponent("__MACOSX")
        for source in files {
            let relative = Array(source.pathComponents.dropFirst(metadata.pathComponents.count))
            guard let name = relative.last, name.count > 2 else { throw AppUpdateError.invalidArchive("AppleDouble 路径无效。") }
            let targetParts = relative.dropLast() + [String(name.dropFirst(2))]
            let targetPath = targetParts.joined(separator: "/")
            try AppUpdateArchiveValidator.validateEntry(targetPath)
            guard !targetParts.contains(".") else { throw AppUpdateError.invalidArchive("AppleDouble 路径别名无效。") }
            let target = root.appendingPathComponent(targetPath)
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw AppUpdateError.invalidArchive("AppleDouble 找不到对应文件。")
            }
            let result = source.path.withCString { from in
                target.path.withCString { to in
                    copyfile(from, to, nil, copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_XATTR | COPYFILE_NOFOLLOW))
                }
            }
            guard result == 0 else { throw AppUpdateError.invalidArchive("无法恢复 macOS 应用元数据。") }
        }
        if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
    }
}

/// libarchive is supplied by macOS. Load its C ABI from the fixed system path, not PATH or user libraries.
private final class ArchiveLibrary {
    let handle: UnsafeMutableRawPointer
    let readNew: @convention(c) () -> OpaquePointer?
    let readFree: @convention(c) (OpaquePointer) -> Int32
    let supportZIP: @convention(c) (OpaquePointer) -> Int32
    let setOptions: @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Int32
    let openFD: @convention(c) (OpaquePointer, Int32, Int) -> Int32
    let nextHeader: @convention(c) (OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    let pathname: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    let filetype: @convention(c) (OpaquePointer) -> UInt32
    let permissions: @convention(c) (OpaquePointer) -> Int32
    let symlink: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    let hardlink: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    let readData: @convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Int
    let errorString: @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?

    init() throws {
        guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw AppUpdateError.invalidArchive("无法载入 macOS ZIP 解码器。")
        }
        self.handle = handle
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else {
                throw AppUpdateError.invalidArchive("macOS ZIP 解码器缺少接口：\(name)")
            }
            return unsafeBitCast(address, to: T.self)
        }
        do {
            readNew = try symbol("archive_read_new", (@convention(c) () -> OpaquePointer?).self)
            readFree = try symbol("archive_read_free", (@convention(c) (OpaquePointer) -> Int32).self)
            supportZIP = try symbol("archive_read_support_format_zip", (@convention(c) (OpaquePointer) -> Int32).self)
            setOptions = try symbol("archive_read_set_options", (@convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Int32).self)
            openFD = try symbol("archive_read_open_fd", (@convention(c) (OpaquePointer, Int32, Int) -> Int32).self)
            nextHeader = try symbol("archive_read_next_header", (@convention(c) (OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> Int32).self)
            pathname = try symbol("archive_entry_pathname_utf8", (@convention(c) (OpaquePointer) -> UnsafePointer<CChar>?).self)
            filetype = try symbol("archive_entry_filetype", (@convention(c) (OpaquePointer) -> UInt32).self)
            permissions = try symbol("archive_entry_perm", (@convention(c) (OpaquePointer) -> Int32).self)
            symlink = try symbol("archive_entry_symlink", (@convention(c) (OpaquePointer) -> UnsafePointer<CChar>?).self)
            hardlink = try symbol("archive_entry_hardlink", (@convention(c) (OpaquePointer) -> UnsafePointer<CChar>?).self)
            readData = try symbol("archive_read_data", (@convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Int).self)
            errorString = try symbol("archive_error_string", (@convention(c) (OpaquePointer) -> UnsafePointer<CChar>?).self)
        } catch { dlclose(handle); throw error }
    }
    func error(_ reader: OpaquePointer) -> String {
        errorString(reader).map(String.init(cString:)) ?? "无法解码 ZIP。"
    }
    deinit { dlclose(handle) }
}
