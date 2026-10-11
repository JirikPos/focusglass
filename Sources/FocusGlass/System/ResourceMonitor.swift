import AppKit
import Darwin

/// Hlídá aplikace, které berou hodně paměti nebo dlouho jedou na plný výkon.
///
/// macOS o tom neposílá žádnou notifikaci, proto se jednou za minutu sečte paměť a čas CPU
/// všech procesů každé aplikace (včetně pomocných – Chrome, Slack, Teams jich mají desítky).
@MainActor
final class ResourceMonitor {
    struct Hog {
        let app: NSRunningApplication
        let name: String
        let memoryGB: Double
        let cpuPercent: Double
        let reason: String
    }

    static let memoryLimitGB = 3.0
    static let cpuLimit = 90.0
    /// Kolik minut v řadě musí aplikace jet nad limitem CPU.
    private static let cpuMinutes = 3
    private static let interval: TimeInterval = 60

    var onHog: ((Hog) -> Void)?

    private var timer: Timer?
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastSample = Date()
    private var cpuStreak: [String: Int] = [:]
    /// Aplikace, které uživatel nechal běžet („Nechat“) → do kdy je ignorovat.
    private var ignored: [String: Date] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        _ = sample() // první vzorek jen jako výchozí bod pro CPU
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// „Nechat“ – tahle aplikace má na 24 hodin klid (např. VS Code s rozšířeními běžně bere víc GB).
    func ignore(_ hog: Hog, for interval: TimeInterval = 24 * 3600) {
        ignored[hog.app.bundleIdentifier ?? hog.name] = Date().addingTimeInterval(interval)
    }

    private func check() {
        for usage in sample() {
            let key = usage.app.bundleIdentifier ?? usage.name
            if let until = ignored[key], until > Date() { continue }

            cpuStreak[key] = usage.cpu >= Self.cpuLimit ? (cpuStreak[key] ?? 0) + 1 : 0
            let reason: String?
            if usage.memoryGB >= Self.memoryLimitGB {
                reason = String(format: "%@ bere %.1f GB", usage.name, usage.memoryGB)
            } else if (cpuStreak[key] ?? 0) >= Self.cpuMinutes {
                reason = "\(usage.name) jede \(Self.cpuMinutes) min na \(Int(usage.cpu)) % CPU"
            } else {
                reason = nil
            }
            guard let reason else { continue }

            // Stejnou aplikaci znovu nejdřív za 30 minut.
            ignored[key] = Date().addingTimeInterval(30 * 60)
            cpuStreak[key] = 0
            onHog?(Hog(app: usage.app, name: usage.name, memoryGB: usage.memoryGB,
                       cpuPercent: usage.cpu, reason: reason))
            return // jedno upozornění za kontrolu
        }
    }

    private struct Usage {
        let app: NSRunningApplication
        let name: String
        let memoryGB: Double
        let cpu: Double
    }

    /// Paměť (footprint) a CPU za poslední interval, sečtené po aplikacích.
    private func sample() -> [Usage] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleURL != nil && $0.processIdentifier != getpid()
        }
        let bundles = apps.map { ($0, $0.bundleURL!.path + "/") }

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))

        var memory: [pid_t: UInt64] = [:]
        var cpuDelta: [pid_t: UInt64] = [:]
        var newCPU: [pid_t: UInt64] = [:]
        var path = [CChar](repeating: 0, count: 4096)

        for pid in pids.prefix(max(0, found)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(cString: path)
            guard let owner = bundles.first(where: { executable.hasPrefix($0.1) })?.0 else { continue }

            var info = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard result == 0 else { continue }

            let ownerPID = owner.processIdentifier
            memory[ownerPID, default: 0] += info.ri_phys_footprint
            let cpuTime = info.ri_user_time + info.ri_system_time
            newCPU[pid] = cpuTime
            if let previous = lastCPU[pid], cpuTime >= previous {
                cpuDelta[ownerPID, default: 0] += cpuTime - previous
            }
        }

        let now = Date()
        let wall = max(1, now.timeIntervalSince(lastSample))
        lastSample = now
        lastCPU = newCPU

        return apps.map { app in
            let pid = app.processIdentifier
            // Časy CPU jsou v jednotkách mach_absolute_time → nanosekundy.
            let nanos = Double(cpuDelta[pid] ?? 0) * Double(timebase.numer) / Double(timebase.denom)
            return Usage(app: app, name: app.localizedName ?? "Aplikace",
                         memoryGB: Double(memory[pid] ?? 0) / 1_073_741_824,
                         cpu: nanos / 1e9 / wall * 100)
        }
        .sorted { $0.memoryGB > $1.memoryGB }
    }
}
