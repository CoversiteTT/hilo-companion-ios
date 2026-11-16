import CryptoKit
import Foundation

enum HiloModel: String, CaseIterable, Codable {
    case hilo = "0205"
    case hiloPlus = "0206"
    case hilo15 = "0209"
    case hiloPlus15 = "020a"

    var name: String { isPlus ? "Hilo Plus" : "Hilo" }
    var isPlus: Bool { self == .hiloPlus || self == .hiloPlus15 }
    var is15: Bool { self == .hilo15 || self == .hiloPlus15 }

    var serviceID: String { uuid("000a") }

    func uuid(_ characteristic: HiloCharacteristic) -> String {
        uuid(characteristic.rawValue)
    }

    private func uuid(_ field: String) -> String {
        "6cd6c8b5-e378-\(rawValue)-\(field)-1b9740683449"
    }

    var presets: [HeatingPreset] {
        if is15 {
            return [
                HeatingPreset(mode: .standard, index: 0, title: "Smooth"),
                HeatingPreset(mode: .standard, index: 1, title: "Smooth+"),
                HeatingPreset(mode: .boost, index: 16, title: "Boost"),
                HeatingPreset(mode: .boost, index: 17, title: "Boost+")
            ]
        }
        return [
            HeatingPreset(mode: .standard, index: 0, title: "5 分 10 秒"),
            HeatingPreset(mode: .standard, index: 1, title: "4 分钟"),
            HeatingPreset(mode: .standard, index: 2, title: "3 分钟")
        ]
    }
}

enum HiloCharacteristic: String, CaseIterable {
    case information = "010a"
    case clock = "020a"
    case battery = "030a"
    case history = "060a"
    case session = "070a"
    case heatingProfile = "0c0a"
}

enum HeatingMode: UInt8, CaseIterable, Codable {
    case standard = 0
    case boost = 1

    var title: String { self == .standard ? "标准模式" : "Boost 模式" }
}

struct HeatingPreset: Hashable, Identifiable {
    let mode: HeatingMode
    let index: UInt8
    let title: String

    var id: UInt8 { index }
}

struct AssignedProfiles: Equatable {
    let standard: UInt8
    let boost: UInt8

    func index(for mode: HeatingMode) -> UInt8 {
        mode == .standard ? standard : boost
    }
}

enum ProfileReply: Equatable {
    case assigned(AssignedProfiles)
    case indexes([UInt8])
    case result(accepted: Bool)
}

struct HiloDeviceInfo {
    let firmware: String
    let historySource: HistorySource?

    init?(_ data: Data, model: HiloModel) {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { return nil }
        firmware = "\(bytes[0]).\(bytes[1]).\(HiloProtocol.uint16(bytes, at: 2))"

        let serialRange = model.isPlus ? 30..<46 : 6..<22
        guard bytes.count >= serialRange.upperBound else {
            historySource = nil
            return
        }
        let serial = bytes[serialRange]
        guard serial.contains(where: { $0 != 0 && $0 != 255 }) else {
            historySource = nil
            return
        }
        // History follows the pen even when the user changes its charger.
        let id = SHA256.hash(data: Data(serial)).map { String(format: "%02x", $0) }.joined()
        let suffix = id.suffix(4).uppercased()
        historySource = HistorySource(id: id, label: "\(model.name) · \(suffix)")
    }
}

struct SessionState: Equatable {
    let isActive: Bool
    let penPresent: Bool

    init?(_ data: Data, model: HiloModel) {
        let bytes = [UInt8](data)
        guard bytes.count >= (model.isPlus ? 3 : 1) else { return nil }
        isActive = bytes[0] != 0
        penPresent = !model.isPlus || bytes[2] == 1
    }
}

struct SessionRecord: Equatable {
    let sequence: UInt32
    let timestamp: UInt32
    let duration: UInt16
    let exitCode: UInt16
    let mode: HeatingMode?

    func date(offset: TimeInterval?, now: Date) -> Date? {
        let seconds = TimeInterval(timestamp)
        let absolute: TimeInterval
        if seconds >= HiloProtocol.unixThreshold {
            absolute = seconds
        } else if let offset {
            absolute = seconds + offset
        } else {
            return nil
        }
        guard absolute >= HiloProtocol.unixThreshold,
              absolute <= now.timeIntervalSince1970 + 300 else { return nil }
        return Date(timeIntervalSince1970: absolute)
    }
}

enum HistoryPacket: Equatable {
    case count(Int)
    case start(Int?)
    case end
    case records([SessionRecord])
}

enum HiloProtocol {
    static let unixThreshold: TimeInterval = 1_704_067_200 // 2024-01-01 UTC
    static let queryProfile = Data([0x00])
    static let queryProfileIndexes = Data([0x01])

    static func setProfile(_ preset: HeatingPreset) -> Data {
        Data([0x03, preset.mode.rawValue, preset.index])
    }

    static func profileReply(_ data: Data) -> ProfileReply? {
        let bytes = [UInt8](data)
        switch bytes.first {
        case 0x00 where bytes.count >= 5:
            return .assigned(AssignedProfiles(standard: bytes[2], boost: bytes[4]))
        case 0x01:
            guard let end = bytes.dropFirst().firstIndex(of: 0xff) else { return nil }
            return .indexes(Array(bytes[1..<end]))
        case 0x03 where bytes.count >= 3:
            return .result(accepted: uint16(bytes, at: 1) == 0xbeef)
        default:
            return nil
        }
    }

    static func clockOffset(_ data: Data, now: Date) -> TimeInterval? {
        let bytes = [UInt8](data)
        guard bytes.count == 4 else { return nil }
        return now.timeIntervalSince1970 - TimeInterval(uint32(bytes, at: 0))
    }

    static func historyPacket(_ data: Data, model: HiloModel) -> HistoryPacket? {
        let bytes = [UInt8](data)
        let recordSize = 19
        if bytes.count == 2 { return .count(Int(uint16(bytes, at: 0))) }
        if bytes.count == 4 || bytes.count == 8 {
            switch uint32(bytes, at: 0) {
            case 0xffff_fffe:
                return .start(bytes.count == 8 ? Int(uint32(bytes, at: 4)) : nil)
            case 0xffff_fffd:
                return .end
            default:
                return nil
            }
        }
        if bytes.count == recordSize {
            return .records([record(bytes, at: 0)])
        }
        guard model.is15, bytes.first == 5, bytes.count > recordSize,
              (bytes.count - 1).isMultiple(of: recordSize) else { return nil }
        let records = stride(from: 1, to: bytes.count, by: recordSize).map {
            record(bytes, at: $0)
        }
        return .records(records)
    }

    private static func record(_ bytes: [UInt8], at offset: Int) -> SessionRecord {
        SessionRecord(
            sequence: uint32(bytes, at: offset),
            timestamp: uint32(bytes, at: offset + 4),
            duration: uint16(bytes, at: offset + 8),
            exitCode: uint16(bytes, at: offset + 10),
            mode: HeatingMode(rawValue: bytes[offset + 12])
        )
    }

    static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(uint16(bytes, at: offset)) << 16) | UInt32(uint16(bytes, at: offset + 2))
    }
}
