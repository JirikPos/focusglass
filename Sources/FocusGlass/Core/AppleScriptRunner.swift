import Foundation

/// Spouští AppleScript na vlastní sériové frontě.
///
/// Na hlavním vlákně by čekání na systémový dotaz o svolení („FocusGlass chce ovládat Safari“)
/// nebo pomalá odpověď aplikace zablokovaly celé UI.
enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "app.focusglass.applescript", qos: .utility)

    static func run(_ source: String, completion: (@MainActor (String?) -> Void)? = nil) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            guard let completion else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(error == nil ? result : nil) }
            }
        }
    }
}
