import Foundation

/// Všechny vestavěné převody a nástroje v pořadí, v jakém je kolo ukazuje.
public enum Catalog {
    public static func makeRegistry() -> OperationRegistry {
        OperationRegistry([])
    }
}
