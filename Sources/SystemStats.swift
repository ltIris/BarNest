import Foundation
import Darwin

/**
 * @Author lt_xiaoyi
 * @Description 采集真实系统数据：CPU、内存、磁盘、网速。温度/GPU 在 macOS 无公开 API，用合理值占位。
 * @Version 1.0
 */
@MainActor
final class SystemStats {
    static let shared = SystemStats()

    var cpuUsage: Double = 0
    var gpuUsage: Double = 0
    var memoryUsed: Double = 0
    var memoryTotal: Double = 0
    var diskUsed: Double = 0
    var temperature: Double = 48
    var netDown: Double = 0   // KB/s
    var netUp: Double = 0     // KB/s

    private var timer: Timer?
    private var prevCPU: host_cpu_load_info_data_t?
    private var prevNet: (down: UInt64, up: UInt64)?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleDisk()
        sampleNetwork()
        gpuUsage = Double.random(in: 3...28)       // 无公开 API，模拟
        temperature = Double.random(in: 44...62)   // 无公开 API，模拟
    }

    // MARK: - CPU
    private func sampleCPU() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, p, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        if let prev = prevCPU {
            let user = info.cpu_ticks.0 - prev.cpu_ticks.0
            let sys = info.cpu_ticks.1 - prev.cpu_ticks.1
            let idle = info.cpu_ticks.2 - prev.cpu_ticks.2
            let nice = info.cpu_ticks.3 - prev.cpu_ticks.3
            let total = user + sys + idle + nice
            if total > 0 {
                cpuUsage = Double(total - idle) / Double(total) * 100
            }
        }
        prevCPU = info
    }

    // MARK: - Memory
    private func sampleMemory() {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, p, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let free = Double(stats.free_count) * Double(pageSize)
        memoryTotal = total
        memoryUsed = max(0, total - free)
    }

    // MARK: - Disk
    private func sampleDisk() {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return }
        let blockSize = Double(fs.f_bsize)
        let total = Double(fs.f_blocks) * blockSize
        let free = Double(fs.f_bfree) * blockSize
        guard total > 0 else { return }
        diskUsed = (total - free) / total * 100
    }

    // MARK: - Network
    private func sampleNetwork() {
        let current = Self.readNetworkBytes()
        if let prev = prevNet {
            let dt = 1.0
            netDown = Double(current.down > prev.down ? current.down - prev.down : 0) / 1024 / dt
            netUp = Double(current.up > prev.up ? current.up - prev.up : 0) / 1024 / dt
        }
        prevNet = current
    }

    private static func readNetworkBytes() -> (down: UInt64, up: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var down: UInt64 = 0, up: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let data = ifa.ifa_data.assumingMemoryBound(to: if_data.self).pointee
                down += UInt64(data.ifi_ibytes)
                up += UInt64(data.ifi_obytes)
            }
            ptr = ifa.ifa_next
        }
        return (down, up)
    }
}
