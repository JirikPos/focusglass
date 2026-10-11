import Foundation

/// Černá stránka „Blocked“, na kterou se přesměruje zablokovaný web.
/// Lokální soubor v Application Support – žádný server, nic se neodesílá.
enum BlockPage {
    static func write(site: String, remaining: String, asksReason: Bool) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusGlass", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("blocked.html")
        let line = asksReason ? "Really need it? Write in the notch why you're going there." : DistractionLines.random()
        try? html(site: site, line: line, remaining: remaining)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func html(site: String, line: String, remaining: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Blocked · FocusGlass</title>
        <style>
          html, body { height: 100%; margin: 0; background: #050505; color: #fff;
            font-family: -apple-system, "SF Pro Display", system-ui, sans-serif; }
          body { display: flex; align-items: center; justify-content: center; }
          main { text-align: center; max-width: 560px; padding: 24px; }
          .label { font-size: 11px; letter-spacing: .3em; text-transform: uppercase; color: rgba(255,255,255,.35); }
          h1 { font-size: 64px; font-weight: 200; margin: 18px 0 10px; letter-spacing: -.01em; }
          p { font-size: 17px; font-weight: 300; color: rgba(255,255,255,.65); margin: 0 0 36px; }
          .time { font-size: 13px; color: rgba(255,255,255,.4); font-variant-numeric: tabular-nums; }
          .line { width: 120px; height: 1px; background: rgba(255,255,255,.15); margin: 0 auto 24px; }
        </style>
        </head>
        <body>
        <main>
          <div class="label">\(escape(site)) · blocked</div>
          <h1>Back to work.</h1>
          <p>\(escape(line))</p>
          <div class="line"></div>
          <div class="time">Focus ends in \(escape(remaining))</div>
        </main>
        </body>
        </html>
        """
    }
}
