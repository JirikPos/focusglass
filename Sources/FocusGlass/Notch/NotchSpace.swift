import AppKit

// Neveřejné rozhraní WindowServeru (SkyLight). Používají ho i NotchNook, boring.notch apod.
// Okno v tomto prostoru zůstává vidět i během animace přepínání ploch a celoobrazovkových aplikací.
// Pozor: kvůli tomu by aplikace neprošla do Mac App Storu.

private typealias CGSConnectionID = Int32
private typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> CGSConnectionID

@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: CGSConnectionID, _ flags: Int32, _ options: NSDictionary?) -> CGSSpaceID

@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int32)

@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)

/// Vlastní „plocha“ nad všemi ostatními, která se při přepínání ploch nehýbe.
@MainActor
final class NotchSpace {
    static let shared = NotchSpace()

    private let connection = _CGSDefaultConnection()
    private let space: CGSSpaceID

    private init() {
        space = CGSSpaceCreate(connection, 0x1, nil)
        CGSSpaceSetAbsoluteLevel(connection, space, Int32.max)
        CGSShowSpaces(connection, [space] as NSArray)
    }

    func add(_ window: NSWindow) {
        CGSAddWindowsToSpaces(connection, [window.windowNumber] as NSArray, [space] as NSArray)
    }
}
