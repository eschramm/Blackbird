//
//           /\
//          |  |                       Blackbird
//          |  |
//         .|  |.       https://github.com/marcoarment/Blackbird
//         $    $
//        /$    $\          Copyright 2022–2023 Marco Arment
//       / $|  |$ \          Released under the MIT License
//      .__$|  |$__.
//           \/
//
//  BlackbirdColumn.swift
//  Created by Marco Arment on 2/27/23.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

internal protocol ColumnWrapper: WrappedType {
    associatedtype ValueType: BlackbirdColumnWrappable
    var value: ValueType { get }
    var valueType: any BlackbirdColumnWrappable.Type { get }
    func hasChanged(in database: Blackbird.Database) -> Bool
    func clearHasChanged(in database: Blackbird.Database)
    /// The column's name, set only on the schema generator's own instance of a model.
    var internalNameInSchemaGenerator: String? { get nonmutating set }
}

/// A column's change tracking, shared by every copy of one model instance (under its `Locked`).
///
/// Not generic, and not nested in the generic `BlackbirdColumn<T>` (which would make it generic
/// over `T` too): a generic class's type metadata for an unspecialized `T` is looked up in the
/// Swift runtime's shared metadata cache each time one is made, and decoding makes one for every
/// column of every row; threads decoding at once contended on that cache.
internal final class BlackbirdColumnState: @unchecked Sendable /* unchecked due to external locking in all uses */ {
    var hasChanged: Bool
    /// The value as last saved or read, a `T`, compared by `BlackbirdColumn<T>.hasChanged(in:)`.
    var lastSavedValue: Any?
    /// The database's ID, not a weak reference to it: forming and dropping a weak reference to
    /// the one shared `Database` for every column of every row is an atomic count that threads
    /// decoding at once contend on. IDs aren't reused, so a closed database's never matches a
    /// new one, as a weak reference gone nil didn't.
    var lastUsedDatabaseID: Blackbird.Database.InstanceID?
    /// Set only on the schema generator's own instance of a model. Kept here rather than in a
    /// lock of its own, which every decoded column paid for.
    var nameInSchemaGenerator: String?

    init(hasChanged: Bool, lastSavedValue: Any? = nil, lastUsedDatabaseID: Blackbird.Database.InstanceID? = nil) {
        self.hasChanged = hasChanged
        self.lastSavedValue = lastSavedValue
        self.lastUsedDatabaseID = lastUsedDatabaseID
    }
}

/// Property wrapper for column variables in ``BlackbirdModel`` `struct` definitions.
@propertyWrapper public struct BlackbirdColumn<T>: ColumnWrapper, WrappedType, Equatable, Sendable, Codable where T: BlackbirdColumnWrappable {
    internal var valueType: any BlackbirdColumnWrappable.Type { T.self }
    
    public static func == (lhs: Self, rhs: Self) -> Bool { type(of: lhs) == type(of: rhs) && lhs.value == rhs.value }
    
    private var _value: T
    private let state: Blackbird.Locked<BlackbirdColumnState>
    var internalNameInSchemaGenerator: String? {
        get { state.withLock { $0.nameInSchemaGenerator } }
        nonmutating set { state.withLock { $0.nameInSchemaGenerator = newValue } }
    }

    public var value: T {
        get { state.withLock { _ in self._value } }
        set { self.wrappedValue = newValue }
    }

    public var projectedValue: BlackbirdColumn<T> { self }
    static internal func schemaGeneratorWrappedType() -> Any.Type { T.self }

    public var wrappedValue: T {
        get { state.withLock { _ in self._value } }
        set {
            state.withLock { state in
                guard self._value != newValue else { return }
                self._value = newValue
                state.hasChanged = true
            }
        }
    }
    
    /// Whether this value has changed since last being saved or read. This errs on the side of over-reporting changes, and may return `true` if the value has not actually changed.
    public func hasChanged(in database: Blackbird.Database) -> Bool {
        state.withLock { state in
            if state.lastUsedDatabaseID != database.id { return true }
            if state.hasChanged { return true }
            // The state above is shared by every copy of an instance, so a sibling copy's
            // save clearing it must not hide this copy's own different, unsaved value.
            guard let saved = state.lastSavedValue as? T else { return true }
            return saved != self._value
        }
    }

    internal func clearHasChanged(in database: Blackbird.Database) {
        state.withLock { state in
            state.lastUsedDatabaseID = database.id
            state.hasChanged = false
            state.lastSavedValue = self._value
        }
    }

    public init(wrappedValue: T) {
        _value = wrappedValue
        state = Blackbird.Locked(BlackbirdColumnState(hasChanged: true))
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(T.self)
        _value = value
        if let sqliteDecoder = decoder as? BlackbirdSQLiteDecoder {
            state = Blackbird.Locked(BlackbirdColumnState(hasChanged: false, lastSavedValue: value, lastUsedDatabaseID: sqliteDecoder.databaseID))
        } else {
            state = Blackbird.Locked(BlackbirdColumnState(hasChanged: true))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }
}

// MARK: - Accessing wrapped types of optionals and column wrappers
internal protocol OptionalProtocol {
    var wrappedOptionalValue: Any? { get }
}
extension Optional: OptionalProtocol {
    var wrappedOptionalValue: Any? {
        get {
            switch self {
                case .some(let w): return w
                default: return nil
            }
        }
    }
}

internal protocol OptionalCreatable {
    associatedtype Wrapped
    static func createFromNilValue() -> Self
    static func createFromValue(_ wrapped: Any) -> Self
    static func creatableWrappedType() -> Any.Type
}

extension Optional: OptionalCreatable {
    static func createFromNilValue() -> Self { .none }
    static func createFromValue(_ wrapped: Any) -> Self { .some(wrapped as! Wrapped) }
    static func creatableWrappedType() -> Any.Type { Wrapped.self }
}

internal protocol WrappedType {
    static func schemaGeneratorWrappedType() -> Any.Type
}

extension Optional: WrappedType {
    internal static func schemaGeneratorWrappedType() -> Any.Type { Wrapped.self }
}

