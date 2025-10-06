//
//  ESAdditions.swift
//  Blackbird
//
//  Created by Eric Schramm on 9/26/25.
//

import Foundation

public enum UUIDError: Error {
    case wrongNumberOfBytesShouldBe16(Int)
}

public extension UUID {
    
    init(data: Data) throws {
        if data.count == MemoryLayout<uuid_t>.size {
            // Create a uuid_t array from Data
            var uuidBytes = [UInt8](repeating: 0, count: 16)
            data.copyBytes(to: &uuidBytes, count: 16)
            
            // Now uuidBytes contains the 16-byte representation of the UUID
            let uuid: uuid_t = (
                uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
            )
            self.init(uuid: uuid)
        } else {
            throw UUIDError.wrongNumberOfBytesShouldBe16(data.count)
        }
    }
    
    var data: Data {
        return withUnsafeBytes(of: uuid) { Data($0) }
    }
}

public extension Blackbird.Value {
    var decimalValue: Decimal? {
        if let stringValue = self.stringValue {
            return Decimal(string: stringValue)
        } else {
            return nil
        }
    }
    
    var uuidValue: UUID? {
        if let dataValue = self.dataValue {
            return try? UUID(data: dataValue)
        } else {
            return nil
        }
    }
    
    var dateValue: Date? {
        if let doubleValue = self.doubleValue {
            return Date(timeIntervalSince1970: doubleValue)
        } else {
            return nil
        }
    }
}

extension UUID: BlackbirdColumnWrappable, BlackbirdStorableAsData {
    public func unifiedRepresentation() -> Data { self.data }
    public static func from(unifiedRepresentation: Data) -> Self { try! UUID(data: unifiedRepresentation) }
    public static func fromValue(_ value: Blackbird.Value) -> Self? { value.uuidValue }
}
