import Foundation
import Testing
@testable import ConvertKit

@Suite struct FileKindTests {
    @Test(arguments: [
        ("png", FileKind.image), ("HEIC", .image), ("svg", .image),
        ("mp4", .video), ("mkv", .video), ("mp3", .audio), ("opus", .audio),
        ("pdf", .pdf), ("docx", .document), ("md", .document), ("textClipping", .document),
        ("pptx", .slides), ("key", .slides), ("xlsx", .spreadsheet), ("csv", .spreadsheet),
        ("epub", .epub), ("srt", .subtitle), ("vtt", .subtitle), ("zip", .archive), ("rar", .archive),
    ])
    func extensionMapsToKind(ext: String, kind: FileKind) {
        #expect(FileKind.of(fileExtension: ext) == kind)
    }

    @Test func unknownExtensionIsOther() {
        #expect(FileKind.of(fileExtension: "qqqzz") == .other)
    }

    @Test func directoryIsFolderButPackageIsNot() throws {
        let root = try TempDir()
        let folder = root.url.appendingPathComponent("Složka")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(FileKind.of(folder) == .folder)
        let rtfd = root.url.appendingPathComponent("Poznámka.rtfd")
        try FileManager.default.createDirectory(at: rtfd, withIntermediateDirectories: true)
        #expect(FileKind.of(rtfd) == .document)
    }
}

@Suite struct SelectionTests {
    @Test func commonKindAndSummary() {
        let one = Selection(urls: [URL(fileURLWithPath: "/tmp/a.png")])
        #expect(one.commonKind == .image)
        #expect(one.summary == "a.png")
        #expect(!one.isMultiple)

        let mixed = Selection(urls: [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.mp3")])
        #expect(mixed.commonKind == nil)
        #expect(mixed.summary == "2 soubory")
    }

    @Test func duplicatesRemovedOrderKept() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let selection = Selection(urls: [b, a, b])
        #expect(selection.urls == [b, a])
    }

    @Test func czechPlurals() {
        #expect(Czech.count(1, "soubor", "soubory", "souborů") == "1 soubor")
        #expect(Czech.count(4, "soubor", "soubory", "souborů") == "4 soubory")
        #expect(Czech.count(5, "soubor", "soubory", "souborů") == "5 souborů")
        #expect(Czech.count(0, "soubor", "soubory", "souborů") == "0 souborů")
    }
}

@Suite struct WheelGeometryTests {
    let geometry = WheelGeometry(count: 8, innerRadius: 50, outerRadius: 150, slop: 20)

    @Test func cardinalDirections() {
        #expect(geometry.segment(dx: 0, dy: 100) == 0)   // nahoře
        #expect(geometry.segment(dx: 100, dy: 0) == 2)   // vpravo
        #expect(geometry.segment(dx: 0, dy: -100) == 4)  // dole
        #expect(geometry.segment(dx: -100, dy: 0) == 6)  // vlevo
    }

    @Test func boundaryJustLeftOfTopIsLastSegment() {
        // Lístek 0 zabírá −22,5° … +22,5°; −30° patří lístku 7.
        let angle = -30.0 * .pi / 180
        #expect(geometry.segment(dx: 100 * sin(angle), dy: 100 * cos(angle)) == 7)
    }

    @Test func centerAndFarOutsideCancel() {
        #expect(geometry.segment(dx: 10, dy: 10) == nil)
        #expect(geometry.segment(dx: 0, dy: 171) == nil)
        #expect(geometry.segment(dx: 0, dy: 169) == 0)
    }

    @Test func stepping() {
        #expect(geometry.step(from: nil, by: 1) == 0)
        #expect(geometry.step(from: nil, by: -1) == 7)
        #expect(geometry.step(from: 7, by: 1) == 0)
        #expect(geometry.step(from: 0, by: -1) == 7)
    }

    @Test func emptyWheel() {
        let empty = WheelGeometry(count: 0, innerRadius: 50, outerRadius: 150)
        #expect(empty.segment(dx: 0, dy: 100) == nil)
        #expect(empty.step(from: nil, by: 1) == nil)
    }
}

@Suite struct OutputPolicyTests {
    @Test func naming() {
        let source = URL(fileURLWithPath: "/x/Dovolená 2024.heic")
        #expect(OutputPolicy.fileName(for: source, tag: "PNG", extension: "png") == "Dovolená 2024 (PNG).png")
        #expect(OutputPolicy.fileName(for: source, tag: nil, extension: "jpg") == "Dovolená 2024.jpg")
        #expect(OutputPolicy.fileName(for: source, tag: "stránky", extension: "") == "Dovolená 2024 (stránky)")
    }

    @Test func uniqueNeverOverwrites() throws {
        let dir = try TempDir()
        let target = dir.url.appendingPathComponent("a.png")
        #expect(OutputPolicy.unique(target) == target)
        try Data().write(to: target)
        #expect(OutputPolicy.unique(target).lastPathComponent == "a 2.png")
        try Data().write(to: dir.url.appendingPathComponent("a 2.png"))
        #expect(OutputPolicy.unique(target).lastPathComponent == "a 3.png")
    }

    @Test func folderLocation() {
        let folder = URL(fileURLWithPath: "/out")
        let policy = OutputPolicy(location: .folder(folder))
        #expect(policy.directory(for: URL(fileURLWithPath: "/in/a.png")) == folder)
    }

    @Test func atomicWriteMovesIntoPlace() async throws {
        let dir = try TempDir()
        let existing = dir.url.appendingPathComponent("r.txt")
        try Data("old".utf8).write(to: existing)
        let result = try await OutputPolicy.write(to: existing) { temp in
            try Data("new".utf8).write(to: temp)
        }
        #expect(result.lastPathComponent == "r 2.txt")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
        #expect(try String(contentsOf: result, encoding: .utf8) == "new")
    }

    @Test func failedWriteLeavesNothing() async throws {
        let dir = try TempDir()
        let target = dir.url.appendingPathComponent("x.txt")
        await #expect(throws: ConvertError.self) {
            _ = try await OutputPolicy.write(to: target) { temp in
                try Data("half".utf8).write(to: temp)
                throw ConvertError.invalidOutput("x.txt")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
    }
}

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputAndLines() async throws {
        let lines = LockedArray<String>()
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'a\\nb\\nc'"], onLine: { lines.append($0) }
        )
        #expect(String(decoding: output.stdout, as: UTF8.self) == "a\nb\nc")
        #expect(lines.values == ["a", "b", "c"])
    }

    @Test func nonZeroExitThrowsWithStderr() async {
        do {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo boom >&2; exit 3"])
            Issue.record("mělo selhat")
        } catch let ConvertError.toolFailed(tool, status, detail) {
            #expect(tool == "sh")
            #expect(status == 3)
            #expect(detail == "boom")
        } catch {
            Issue.record("nečekaná chyba \(error)")
        }
    }

    @Test func cancellationTerminatesProcess() async {
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"])
        }
        try? await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(throws: CancellationError.self) { try result.get() }
    }
}

@Suite struct ToolLocatorTests {
    @Test func envDisablesTool() {
        let locator = ToolLocator(searchPaths: ["/bin"], environment: ["FG_NO_FFMPEG": "1", "PATH": ""])
        #expect(locator.url(for: .ffmpeg) == nil)
    }

    @Test func findsExecutableInSearchPath() throws {
        let dir = try TempDir()
        let fake = dir.url.appendingPathComponent("pandoc")
        try Data("#!/bin/sh\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let locator = ToolLocator(searchPaths: [dir.url.path], environment: ["PATH": ""])
        #expect(locator.url(for: .pandoc)?.path == fake.path)
        #expect(locator.url(for: .cwebp) == nil || locator.url(for: .cwebp)?.path.hasPrefix(dir.url.path) == false)
    }
}

@Suite struct RegistryAndQueueTests {
    @Test func registryFiltersByWheelAndSelection() {
        let registry = OperationRegistry([
            FakeOperation(id: "a", wheel: .convert, kind: .image),
            FakeOperation(id: "b", wheel: .tools, kind: .image),
            FakeOperation(id: "c", wheel: .convert, kind: .video),
        ])
        let image = Selection(urls: [URL(fileURLWithPath: "/a.png")])
        #expect(registry.operations(for: image, wheel: .convert).map(\.id) == ["a"])
        #expect(registry.operations(for: image, wheel: .tools).map(\.id) == ["b"])
        #expect(registry.operations(for: Selection(urls: []), wheel: .convert).isEmpty)
    }

    @Test func missingToolIsReported() {
        let op = FakeOperation(id: "x", wheel: .convert, kind: .video, requirements: [.tool(.ffmpeg)])
        let locator = ToolLocator(searchPaths: [], environment: ["FG_NO_FFMPEG": "1", "PATH": ""])
        #expect(op.availability(tools: locator) == .missing(hint: "brew install ffmpeg"))
    }

    @Test func queueRunsAndReportsFinished() async throws {
        let queue = JobQueue()
        let op = FakeOperation(id: "ok", wheel: .convert, kind: .image)
        let id = await queue.submit(op, selection: Selection(urls: [URL(fileURLWithPath: "/a.png")]), output: OutputPolicy())
        let final = await finalState(of: id, in: queue)
        #expect(final == .finished([URL(fileURLWithPath: "/done")]))
    }

    @Test func queueCancelsRunningJob() async throws {
        let queue = JobQueue()
        let op = FakeOperation(id: "slow", wheel: .convert, kind: .image, delay: .seconds(30))
        let id = await queue.submit(op, selection: Selection(urls: [URL(fileURLWithPath: "/a.png")]), output: OutputPolicy())
        try await Task.sleep(for: .milliseconds(100))
        await queue.cancel(id)
        let final = await finalState(of: id, in: queue)
        #expect(final == .cancelled)
    }

    @Test func queueReportsFailure() async throws {
        let queue = JobQueue()
        let op = FakeOperation(id: "bad", wheel: .convert, kind: .image, error: ConvertError.unreadable("a.png"))
        let id = await queue.submit(op, selection: Selection(urls: [URL(fileURLWithPath: "/a.png")]), output: OutputPolicy())
        let final = await finalState(of: id, in: queue)
        #expect(final == .failed(message: "Soubor „a.png“ nejde přečíst", detail: nil))
    }

    private func finalState(of id: UUID, in queue: JobQueue) async -> JobSnapshot.State? {
        for await snapshot in queue.updates where snapshot.id == id && snapshot.state.isDone {
            return snapshot.state
        }
        return nil
    }
}

// MARK: - Pomocníci

struct FakeOperation: FileOperation {
    let id: String
    let wheel: Wheel
    let kind: FileKind
    var requirements: [Requirement] = []
    var delay: Duration = .zero
    var error: ConvertError?

    var title: String { id }

    func accepts(_ selection: Selection) -> Bool { selection.commonKind == kind }

    func run(_ context: OperationContext) async throws -> [URL] {
        context.progress(0.5)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return [URL(fileURLWithPath: "/done")]
    }
}

final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ConvertKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []

    func append(_ value: T) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [T] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
