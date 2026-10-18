import Foundation

/// Seznam všech operací. Kolo se ptá, co nabídnout pro daný výběr.
public struct OperationRegistry: Sendable {
    public private(set) var operations: [any FileOperation] = []

    public init(_ operations: [any FileOperation] = []) {
        operations.forEach { register($0) }
    }

    public mutating func register(_ operation: any FileOperation) {
        precondition(!operations.contains { $0.id == operation.id }, "Duplicitní operace \(operation.id)")
        operations.append(operation)
    }

    public mutating func register(_ list: [any FileOperation]) {
        list.forEach { register($0) }
    }

    /// Operace pro výběr v pořadí registrace.
    public func operations(for selection: Selection, wheel: Wheel) -> [any FileOperation] {
        guard !selection.isEmpty else { return [] }
        return operations.filter { $0.wheel == wheel && $0.accepts(selection) }
    }

    public func operation(id: String) -> (any FileOperation)? {
        operations.first { $0.id == id }
    }
}
