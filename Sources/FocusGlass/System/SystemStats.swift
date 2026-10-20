import Darwin
import Foundation
import Observation

/// Živé hodnoty počítače: zátěž po jádrech, paměť, síť, tepelný stav.
///
/// Měří se jen mezi `start()` a `stop()` – karta je zapíná, když je okno z lišty otevřené,
/// takže na pozadí to nestojí nic. Žádné soukromé API: teplotu zastupuje veřejný
/// `ProcessInfo.thermalState`.
@MainActor
@Observable
final class SystemStats {
    private(set) var cores: [Double] = []
    private(set) var memoryUsed: Double = 0
    private(set) var memoryTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    private(set) var download: Double = 0
    private(set) var upload: Double = 0
    private(set) var thermal: ProcessInfo.ThermalState = .nominal

    var cpu: Double { cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count) }
    var memoryFraction: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTicks: [[UInt32]] = []
    @ObservationIgnored private var lastNet: (down: UInt64, up: UInt64)?
    @ObservationIgnored private var lastSample = Date()

    func start() {
        guard timer == nil else { return }
        lastTicks = []
        lastNet = nil
        lastSample = Date()
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let now = Date()
        let wall = max(0.2, now.timeIntervalSince(lastSample))
        lastSample = now

        sampleCPU()
        sampleMemory()
        sampleNetwork(over: wall)
        thermal = ProcessInfo.processInfo.thermalState
    }

    // MARK: CPU

    private func sampleCPU() {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let stride = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for core in 0..<Int(count) {
            ticks.append((0..<stride).map { UInt32(bitPattern: info[core * stride + $0]) })
        }
        defer { lastTicks = ticks }
        guard lastTicks.count == ticks.count else { return }

        cores = zip(ticks, lastTicks).map { now, before in
            let delta = (0..<stride).map { now[$0] &- before[$0] }
            let total = delta.reduce(0, { $0 + Double($1) })
            let idle = Double(delta[Int(CPU_STATE_IDLE)])
            return total > 0 ? min(1, max(0, 1 - idle / total)) : 0
        }
    }

    // MARK: Paměť

    private func sampleMemory() {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // Stejný součet jako v Monitoru aktivity: aplikace + vázaná + komprimovaná.
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        memoryUsed = Double(pages) * Double(vm_kernel_page_size)
    }

    // MARK: Síť

    private func sampleNetwork(over wall: TimeInterval) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return }
        defer { freeifaddrs(head) }

        var down: UInt64 = 0
        var up: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = entry.ifa_data,
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(counters.ifi_ibytes)
            up += UInt64(counters.ifi_obytes)
        }

        defer { lastNet = (down, up) }
        guard let last = lastNet else { return }
        // Čítače jsou 32bitové a přetékají – záporný rozdíl bereme jako 0.
        download = down >= last.down ? Double(down - last.down) / wall : 0
        upload = up >= last.up ? Double(up - last.up) / wall : 0
    }
}
