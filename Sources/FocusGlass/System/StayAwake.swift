import Foundation
import Observation

/// Mac nespí ani při zavřeném víku (`pmset disablesleep`). Vždy jen na výslovné zapnutí
/// a nikdy se neukládá – po každém spuštění aplikace je vypnuto.
///
/// Běžné „caffeinate“ / power assertions zavřené víko nepřebijí, `disablesleep` ano, ale vyžaduje root.
/// Při prvním zapnutí proto jednou požádáme o heslo správce a nainstalujeme úzké pravidlo
/// (`/etc/sudoers.d/focusglass`), které povolí jen `pmset -a disablesleep 0|1`. Další přepnutí jsou bez hesla.
@MainActor
@Observable
final class StayAwake {
    private(set) var isOn = false
    private(set) var isBusy = false

    /// Chyba k zobrazení uživateli (zrušené heslo, selhání pmset…).
    @ObservationIgnored var onError: ((String) -> Void)?

    private nonisolated static let sudoersPath = "/etc/sudoers.d/focusglass"

    /// Po pádu mohlo zůstat zapnuto – při startu vrátíme výchozí stav.
    func resetOnLaunch() {
        Task.detached {
            guard Self.systemSleepDisabled(), Self.runPmset(on: false) else { return }
        }
    }

    func set(_ on: Bool) {
        guard on != isOn, !isBusy else { return }
        isBusy = true
        Task.detached {
            let result = await Self.apply(on)
            await MainActor.run {
                self.isBusy = false
                switch result {
                case .success: self.isOn = on
                case .failure(let failure):
                    if let message = failure.message { self.onError?(message) }
                }
            }
        }
    }

    /// Synchronně, při ukončení aplikace. Bez hesla – pravidlo už existuje, pokud bylo zapnuto.
    func restoreOnQuit() {
        guard isOn else { return }
        _ = Self.runPmset(on: false)
        isOn = false
    }

    // MARK: - Systém

    private struct Failure: Error { let message: String? }

    private nonisolated static func apply(_ on: Bool) async -> Result<Void, Failure> {
        if runPmset(on: on) { return .success(()) }
        // Vypnutí bez práv nejde nijak „opravit“ – pravidlo prostě chybí.
        guard on else { return .failure(Failure(message: "Nepodařilo se vrátit spánek. Zkus: sudo pmset -a disablesleep 0")) }

        switch installRule() {
        case .cancelled: return .failure(Failure(message: nil))
        case .failed: return .failure(Failure(message: "Nepodařilo se získat oprávnění pro pmset."))
        case .installed:
            return runPmset(on: true)
                ? .success(())
                : .failure(Failure(message: "pmset disablesleep selhal."))
        }
    }

    /// `sudo -n` selže hned, pokud pravidlo neexistuje (nikdy nečeká na heslo).
    private nonisolated static func runPmset(on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
    }

    private nonisolated static func systemSleepDisabled() -> Bool {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").contains {
            $0.contains("SleepDisabled") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
    }

    private enum InstallResult { case installed, cancelled, failed }

    private nonisolated static func installRule() -> InstallResult {
        let user = NSUserName()
        // Jméno jde do sudoers a do shellu – povolíme jen běžný tvar.
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return .failed }

        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let temp = "/private/tmp/focusglass-sudoers-\(getpid())"
        // visudo -c ověří syntaxi dřív, než se soubor dostane do sudoers.d (chybný soubor by zablokoval sudo).
        let script = """
        printf '%s\\n' '\(rule)' > \(temp) && /usr/sbin/visudo -cf \(temp) \
        && /usr/sbin/chown root:wheel \(temp) && /bin/chmod 440 \(temp) \
        && /bin/mv \(temp) \(sudoersPath) || { /bin/rm -f \(temp); exit 1; }
        """
        let source = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return .installed }
        // -128 = uživatel zrušil dialog s heslem.
        return (error[NSAppleScript.errorNumber] as? Int) == -128 ? .cancelled : .failed
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
