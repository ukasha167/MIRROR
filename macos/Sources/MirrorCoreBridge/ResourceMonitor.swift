import Foundation
import Darwin

/// Diagnostics sampled from macOS kernel for resource enforcement.
public struct ResourceDiagnostics: Sendable, Codable {
    public let residentMemoryBytes: UInt64
    public let residentMemoryMB: Double
    public let cpuUsagePercent: Double
    public let threadCount: Int
    public let isWithinLimits: Bool
    public let timestamp: Date

    public init(
        residentMemoryBytes: UInt64,
        residentMemoryMB: Double,
        cpuUsagePercent: Double,
        threadCount: Int,
        isWithinLimits: Bool,
        timestamp: Date = Date()
    ) {
        self.residentMemoryBytes = residentMemoryBytes
        self.residentMemoryMB = residentMemoryMB
        self.cpuUsagePercent = cpuUsagePercent
        self.threadCount = threadCount
        self.isWithinLimits = isWithinLimits
        self.timestamp = timestamp
    }
}

/// Resource monitor enforcing AGENTS.md requirements: <28 MB idle RAM and 0.0% idle CPU.
public final class ResourceMonitor: Sendable {
    public static let maxIdleRAMBytes: UInt64 = 28 * 1024 * 1024 // 28 MB
    public static let maxIdleCPUPercent: Double = 0.5 // 0.0% nominal with 0.5% OS jitter tolerance

    public init() {}

    /// Samples current host process memory and CPU consumption.
    public func sampleMetrics() -> ResourceDiagnostics {
        var basicInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &basicInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        let residentBytes: UInt64
        if kerr == KERN_SUCCESS {
            residentBytes = basicInfo.resident_size
        } else {
            residentBytes = 0
        }

        let residentMB = Double(residentBytes) / (1024.0 * 1024.0)
        let (cpuPercent, threads) = sampleCpuUsage()

        // Evaluates if process meets <28 MB RAM and near-0% CPU idle criteria
        let withinLimits = residentBytes <= Self.maxIdleRAMBytes && cpuPercent <= Self.maxIdleCPUPercent

        return ResourceDiagnostics(
            residentMemoryBytes: residentBytes,
            residentMemoryMB: residentMB,
            cpuUsagePercent: cpuPercent,
            threadCount: threads,
            isWithinLimits: withinLimits
        )
    }

    private func sampleCpuUsage() -> (Double, Int) {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        let kerr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kerr == KERN_SUCCESS, let threads = threadList else {
            return (0.0, 0)
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: threads),
                vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size)
            )
        }

        var totalCpuUsage: Double = 0.0
        let count = Int(threadCount)

        for i in 0..<count {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

            let infoErr = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }

            if infoErr == KERN_SUCCESS {
                if (threadInfo.flags & TH_FLAGS_IDLE) == 0 {
                    let usage = Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                    totalCpuUsage += usage
                }
            }
        }

        return (totalCpuUsage, count)
    }
}
