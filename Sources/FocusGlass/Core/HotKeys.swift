import Carbon.HIToolbox

/// Globální klávesové zkratky přes Carbon `RegisterEventHotKey` – nepotřebují žádná oprávnění
/// a nic nehlídají na pozadí (systém zavolá handler jen při stisku).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    enum Modifier {
        static let control = UInt32(controlKey)
        static let option = UInt32(optionKey)
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeys.shared.actions[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers,
                                         EventHotKeyID(signature: OSType(0x4647_4C53), id: id), // "FGLS"
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        refs.append(ref)
        actions[id] = action
    }
}
