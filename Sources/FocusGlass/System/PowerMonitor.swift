import Foundation
import IOKit.ps

/// Stav baterie. O každé změně napájení dá vědět systém (IOKit) – nic se nekontroluje.
@MainActor
final class PowerMonitor {
    struct State: Equatable {
        let percent: Int
        let isCharging: Bool
        let onAC: Bool
    }

    /// Připojena nabíječka.
    var onPluggedIn: ((State) -> Void)?
    /// Baterie klesla na 20 % / 10 % (jednou za vybíjení).
    var onLow: ((State) -> Void)?

    private var last: State?
    private var warned: Set<Int> = []
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil, Self.read() != nil else { return } // Mac bez baterie
        last = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.changed() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        source = created
    }

    private func changed() {
        guard let state = Self.read() else { return }
        defer { last = state }

        if state.onAC, last?.onAC == false {
            warned.removeAll()
            onPluggedIn?(state)
        }
        if !state.onAC {
            for threshold in [20, 10] where state.percent <= threshold && !warned.contains(threshold) {
                // Jen při skutečném poklesu přes hranici, ne hned po odpojení pod ní.
                if let previous = last?.percent, previous > threshold {
                    warned.insert(threshold)
                    onLow?(state)
                }
            }
        }
    }

    static func read() -> State? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = max(1, description[kIOPSMaxCapacityKey] as? Int ?? 100)
            return State(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }
}
