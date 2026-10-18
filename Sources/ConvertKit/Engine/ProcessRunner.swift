import Foundation

/// Spouští externí nástroje. Argumenty vždy jako pole (žádný shell, žádné escapování),
/// zrušení úlohy pošle SIGTERM a po chvíli SIGKILL.
public enum ProcessRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
    }

    /// - Parameter onLine: každý řádek standardního výstupu (např. `ffmpeg -progress pipe:1`).
    /// - Throws: `ConvertError.toolFailed` při nenulovém exit kódu, `CancellationError` při zrušení.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let out = Buffer(onLine: onLine)
        let err = Buffer(onLine: nil)
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            terminate(process)
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        out.flush()

        if Task.isCancelled { throw CancellationError() }
        let output = Output(status: status, stdout: out.data, stderr: err.text)
        guard status == 0 else {
            throw ConvertError.toolFailed(
                tool: executable.lastPathComponent,
                status: status,
                detail: String(output.stderr.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Vlákno-bezpečný sběr výstupu s dělením na řádky.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var pending = Data()
        private let onLine: (@Sendable (String) -> Void)?

        init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            storage.append(chunk)
            var lines: [String] = []
            if onLine != nil {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            lock.unlock()
            lines.forEach { onLine?($0) }
        }

        func flush() {
            lock.lock()
            let rest = pending
            pending.removeAll()
            lock.unlock()
            if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var text: String { String(decoding: data, as: UTF8.self) }
    }
}
