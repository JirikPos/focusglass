import Foundation
import OSLog

private let log = Logger(subsystem: "app.focusglass", category: "convert")

/// Stav jedné úlohy pro UI.
public struct JobSnapshot: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case queued
        case running(progress: Double)
        case finished([URL])
        case failed(message: String, detail: String?)
        case cancelled

        public var isDone: Bool {
            switch self {
            case .queued, .running: false
            case .finished, .failed, .cancelled: true
            }
        }
    }

    public let id: UUID
    public let operationID: String
    public let title: String
    public let subtitle: String
    public let started: Date
    public var state: State
}

/// Fronta převodů. Lehké operace běží souběžně, těžké (video) po jedné,
/// aby Mac nezamrzl a baterie nezmizela.
public actor JobQueue {
    private struct Entry {
        let operation: any FileOperation
        let context: OperationContext
        var snapshot: JobSnapshot
        var task: Task<Void, Never>?
        var lastReported: Double = 0
    }

    private let limits: [Lane: Int]
    private var entries: [UUID: Entry] = [:]
    private var pending: [UUID] = []
    private var running: [Lane: Int] = [:]

    public nonisolated let updates: AsyncStream<JobSnapshot>
    private let continuation: AsyncStream<JobSnapshot>.Continuation

    public init(
        lightLimit: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        heavyLimit: Int = 1
    ) {
        limits = [.light: lightLimit, .heavy: heavyLimit]
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    deinit { continuation.finish() }

    /// Zařadí operaci. `context.progress` se nahradí hlášením do fronty.
    @discardableResult
    public func submit(
        _ operation: any FileOperation,
        selection: Selection,
        output: OutputPolicy,
        tools: ToolLocator = .shared,
        options: [String: OptionValue] = [:]
    ) -> UUID {
        let id = UUID()
        let context = OperationContext(
            selection: selection, output: output, tools: tools, options: options,
            progress: { [weak self] value in
                Task { await self?.report(id, progress: value) }
            }
        )
        let snapshot = JobSnapshot(
            id: id, operationID: operation.id, title: operation.title,
            subtitle: selection.summary, started: Date(), state: .queued
        )
        entries[id] = Entry(operation: operation, context: context, snapshot: snapshot)
        pending.append(id)
        continuation.yield(snapshot)
        pump()
        return id
    }

    public func cancel(_ id: UUID) {
        guard var entry = entries[id] else { return }
        if let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            entry.snapshot.state = .cancelled
            entries[id] = nil
            continuation.yield(entry.snapshot)
        } else {
            entry.task?.cancel()
        }
    }

    public func cancelAll() {
        for id in Array(entries.keys) { cancel(id) }
    }

    public var activeCount: Int { entries.count }

    private func pump() {
        for id in pending {
            guard let entry = entries[id] else { continue }
            let lane = entry.operation.lane
            guard running[lane, default: 0] < limits[lane, default: 1] else { continue }
            start(id)
        }
    }

    private func start(_ id: UUID) {
        guard var entry = entries[id] else { return }
        pending.removeAll { $0 == id }
        running[entry.operation.lane, default: 0] += 1
        entry.snapshot.state = .running(progress: 0)
        continuation.yield(entry.snapshot)

        let operation = entry.operation
        let context = entry.context
        entry.task = Task { [weak self] in
            let state: JobSnapshot.State
            do {
                let urls = try await operation.run(context)
                state = Task.isCancelled ? .cancelled : .finished(urls)
            } catch is CancellationError {
                state = .cancelled
            } catch ConvertError.cancelled {
                state = .cancelled
            } catch {
                let detail = (error as? LocalizedError)?.failureReason
                log.error("\(operation.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                state = .failed(message: error.localizedDescription, detail: detail)
            }
            await self?.finish(id, state: state)
        }
        entries[id] = entry
    }

    private func report(_ id: UUID, progress: Double) {
        guard var entry = entries[id], case .running = entry.snapshot.state else { return }
        let value = min(max(progress, 0), 1)
        // Neposílat UI stovky aktualizací za sekundu.
        guard value - entry.lastReported >= 0.01 || value >= 1 else { return }
        entry.lastReported = value
        entry.snapshot.state = .running(progress: value)
        entries[id] = entry
        continuation.yield(entry.snapshot)
    }

    private func finish(_ id: UUID, state: JobSnapshot.State) {
        guard var entry = entries.removeValue(forKey: id) else { return }
        running[entry.operation.lane, default: 1] -= 1
        entry.snapshot.state = state
        continuation.yield(entry.snapshot)
        pump()
    }
}
