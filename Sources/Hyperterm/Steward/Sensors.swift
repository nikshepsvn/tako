import Darwin
import Foundation

/// How hard macOS is squeezing memory, as the kernel reports it.
enum MemoryPressure: String, Codable, Comparable {
    case normal, warning, critical

    private var rank: Int { self == .normal ? 0 : self == .warning ? 1 : 2 }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical. Polled because a
    /// pressure source may never signal the return to normal.
    static func current() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return level >= 4 ? .critical : level >= 2 ? .warning : .normal
    }
}

/// ProcessInfo.ThermalState, codable by name.
enum Thermal: String, Codable, Comparable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    private var rank: Int { [.nominal, .fair, .serious, .critical].firstIndex(of: self) ?? 0 }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

enum HostMemory {
    static var totalBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Memory a new process can take without forcing compression or swap: free, speculative and
    /// inactive pages.
    static func availableBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.free_count) + UInt64(stats.speculative_count) + UInt64(stats.inactive_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    /// Performance cores (hw.perflevel0), or all cores on a Mac without levels.
    static var performanceCores: Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return Int(cores) }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}

/// One process's footprint (what Activity Monitor calls Memory, not RSS) and CPU time so far.
struct ProcessUsage {
    var footprint: UInt64
    var cpuNanoseconds: UInt64

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    static func read(_ pid: pid_t) -> ProcessUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // rusage times are mach ticks on Apple silicon.
        let ticks = info.ri_user_time + info.ri_system_time
        return ProcessUsage(footprint: info.ri_phys_footprint, cpuNanoseconds: ticks * timebase.numer / timebase.denom)
    }

    /// Tako's own Chromium: its helpers (renderers, GPU, network) run as Tako's children from the
    /// app bundle's Frameworks, outside every session's process tree.
    static func browserProcesses() -> (count: Int, footprint: UInt64) {
        var pids = [pid_t](repeating: 0, count: 1024)
        let returned = Int(proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        // libproc answers in pids on some releases and bytes on others.
        let count = min(returned > pids.count ? returned / MemoryLayout<pid_t>.size : returned, pids.count)
        var total: (count: Int, footprint: UInt64) = (0, 0)
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            guard path(pid)?.contains(".app/Contents/Frameworks/") == true, let usage = read(pid) else { continue }
            total.count += 1
            total.footprint += usage.footprint
        }
        return total
    }

    /// The process's executable path.
    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's short name (its executable's), e.g. "claude" or "node".
    static func name(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// A session tree's CPU, from per-process time deltas between two samples. Processes that
/// appear between samples count in full; ones that exit drop out.
struct CPUMeter {
    private var last: [pid_t: UInt64] = [:]
    private var lastAt: TimeInterval?

    /// Percent of one core (can pass 100), or nil on the first sample.
    mutating func update(_ times: [pid_t: UInt64], at now: TimeInterval) -> Double? {
        defer { last = times; lastAt = now }
        guard let lastAt, now > lastAt else { return nil }
        var used: UInt64 = 0
        for (pid, time) in times {
            let before = last[pid] ?? 0
            if time > before { used += time - before }
        }
        return Double(used) / ((now - lastAt) * 1e9) * 100
    }
}
