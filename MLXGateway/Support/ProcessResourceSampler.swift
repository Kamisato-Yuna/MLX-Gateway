import Foundation
import Darwin

struct ProcessResourceReading: Sendable {
    let pid: Int32
    let startedAt: UInt64
    let sampledAt: Double
    let cpuNanoseconds: UInt64
    let residentBytes: UInt64
    let footprintBytes: UInt64
    let readBytes: UInt64
    let writtenBytes: UInt64
}

enum ProcessResourceSampler {
    static func read(pid: Int32) -> ProcessResourceReading? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return ProcessResourceReading(pid: pid, startedAt: info.ri_proc_start_abstime,
            sampledAt: ProcessInfo.processInfo.systemUptime,
            cpuNanoseconds: info.ri_user_time + info.ri_system_time,
            residentBytes: info.ri_resident_size, footprintBytes: info.ri_phys_footprint,
            readBytes: info.ri_diskio_bytesread, writtenBytes: info.ri_diskio_byteswritten)
    }

    static func cpuPercent(current: ProcessResourceReading, previous: ProcessResourceReading?) -> Double? {
        guard let previous, previous.pid == current.pid, previous.startedAt == current.startedAt,
              current.sampledAt > previous.sampledAt, current.cpuNanoseconds >= previous.cpuNanoseconds else { return nil }
        return Double(current.cpuNanoseconds - previous.cpuNanoseconds) / 1_000_000_000
            / (current.sampledAt - previous.sampledAt) * 100
    }
}
