import Darwin
import Foundation

/// Tako's footprint over time, in events.jsonl: one line an hour, so a slow climb (1.3–2.0 GB
/// after ~233 hours in a Jetsam report) shows when it started and what it tracked; and once per
/// run, the first time Tako passes `highWater`, a breakdown of where the memory is, so the
/// growth can be diagnosed from the log afterwards. The steward already reads the footprint
/// each tick; this only decides when to write it down.
struct FootprintTrend {
    static let interval: TimeInterval = 3600
    /// Well above a fresh Tako with a few dozen terminals, well below `TakoFootprint.warnBytes`:
    /// early enough that the breakdown catches the growth, not the aftermath.
    static let highWater: UInt64 = 1536 << 20

    private(set) var lastLogged: Date?
    /// Taken (or started) this run; never again, whatever the footprint does next.
    private(set) var breakdownTaken = false

    struct Due: Equatable {
        var log = false
        var breakdown = false
    }

    /// The first reading is logged as the run's baseline, then one an hour.
    mutating func update(_ bytes: UInt64, now: Date) -> Due {
        var due = Due()
        if lastLogged.map({ now.timeIntervalSince($0) >= Self.interval }) ?? true {
            lastLogged = now
            due.log = true
        }
        if bytes >= Self.highWater, !breakdownTaken {
            breakdownTaken = true
            due.breakdown = true
        }
        return due
    }

    /// The hourly line's fields.
    static func fields(footprint: UInt64, sessions: Int, uptime: TimeInterval, notifications: (sent: Int, suppressed: Int)) -> [String: Any] {
        ["footprint": footprint, "sessions": sessions, "uptime_s": Int(uptime),
         "notified": notifications.sent, "suppressed": notifications.suppressed]
    }
}

/// What `vmmap --summary` would say about Tako itself, read in-process: the VM totals, dirty and
/// swapped memory by region tag (malloc, CoreAnimation, IOSurface, JavaScriptCore…), and bytes
/// in use per malloc zone. One pass over the address space; run off the main thread, once.
enum MemoryBreakdown {
    /// Regions looked at, at most: Tako has a few thousand; this bounds a pathological map.
    static let regionLimit = 200_000

    static func capture(topTags: Int = 12) -> [String: Any] {
        var result: [String: Any] = [:]
        if let info = vmInfo() {
            result["vm_mb"] = [
                "footprint": mb(info.phys_footprint), "internal": mb(info.internal), "compressed": mb(info.compressed),
                "external": mb(info.external), "reusable": mb(info.reusable), "purgeable": mb(info.purgeable_volatile_pmap),
            ]
        }
        let tags = regionsByTag().sorted { $0.value > $1.value }.prefix(topTags)
        result["tags_mb"] = Dictionary(uniqueKeysWithValues: tags.map { ($0.key, mb($0.value)) })
        result["zones_mb"] = mallocZones().filter { $0.value >= 1 << 20 }.mapValues { mb($0) }
        return result
    }

    private static func mb(_ bytes: UInt64) -> Int { Int(bytes >> 20) }

    static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// Dirty plus swapped bytes per region tag: what each kind of memory adds to the footprint.
    static func regionsByTag() -> [String: UInt64] {
        var totals: [String: UInt64] = [:]
        var address: mach_vm_address_t = 0
        var depth: natural_t = 0
        let page = UInt64(vm_kernel_page_size)
        for _ in 0..<regionLimit {
            var size: mach_vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { break }
            if info.is_submap != 0 {
                depth += 1
                continue
            }
            let bytes = (UInt64(info.pages_dirtied) + UInt64(info.pages_swapped_out)) * page
            if bytes > 0 { totals[tagName(Int32(info.user_tag)), default: 0] += bytes }
            address += size
        }
        return totals
    }

    /// Bytes in use per malloc zone ("DefaultMallocZone", "QuartzCore", …).
    static func mallocZones() -> [String: UInt64] {
        var addresses: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        guard malloc_get_all_zones(mach_task_self_, nil, &addresses, &count) == KERN_SUCCESS, let addresses else { return [:] }
        var zones: [String: UInt64] = [:]
        for index in 0..<Int(count) {
            guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(addresses[index])) else { continue }
            var stats = malloc_statistics_t()
            malloc_zone_statistics(zone, &stats)
            let name = malloc_get_zone_name(zone).map { String(cString: $0) } ?? "zone \(index)"
            zones[name, default: 0] += UInt64(stats.size_in_use)
        }
        return zones
    }

    /// vmmap's names for the region tags that matter in an AppKit app hosting terminals and CEF.
    static func tagName(_ tag: Int32) -> String {
        let names: [Int32: String] = [
            0: "untagged", 1: "MALLOC", 2: "MALLOC_SMALL", 3: "MALLOC_LARGE", 4: "MALLOC_HUGE", 7: "MALLOC_TINY",
            8: "MALLOC_LARGE_REUSABLE", 9: "MALLOC_LARGE_REUSED", 11: "MALLOC_NANO", 12: "MALLOC_MEDIUM",
            20: "Mach message", 21: "IOKit", 30: "Stack", 31: "Guard", 33: "Dylib", 35: "Unshared pmap",
            40: "AppKit", 41: "Foundation", 42: "CoreGraphics", 43: "CoreServices", 50: "ATS (font support)",
            51: "CoreAnimation", 52: "CG image", 54: "CoreGraphics data", 55: "CoreGraphics shared",
            56: "CG framebuffers", 57: "CG backingstores", 60: "dyld", 61: "dyld private memory", 62: "SQLite",
            63: "JavaScriptCore", 64: "JS JIT generated code", 66: "OpenGL GLSL", 68: "CoreImage", 70: "ImageIO",
            73: "OS Alloc Once", 74: "Dispatch continuations", 76: "CoreUI image data", 82: "Swift runtime",
            83: "Swift metadata", 88: "IOSurface", 89: "libnetwork", 90: "Audio", 100: "IOAccelerator",
            103: "CoreUI cached image data", 104: "ColorSync",
        ]
        return names[tag] ?? "tag \(tag)"
    }
}
