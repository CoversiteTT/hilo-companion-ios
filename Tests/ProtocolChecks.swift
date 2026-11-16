import Foundation

@main
struct ProtocolChecks {
    static func main() throws {
        let uuidParts = ["0205", "0206", "0209", "020a"]
        for (model, part) in zip(HiloModel.allCases, uuidParts) {
            expect(model.serviceID == "6cd6c8b5-e378-\(part)-000a-1b9740683449", "service for \(model)")
            expect(model.uuid(.history) == "6cd6c8b5-e378-\(part)-060a-1b9740683449", "history characteristic for \(model)")
            expect(model.uuid(.heatingProfile) == "6cd6c8b5-e378-\(part)-0c0a-1b9740683449", "profile characteristic for \(model)")
            expect(model.diagnosticServiceID == "6cd6c8b5-e378-\(part)-000b-1b9740683449", "diagnostic service for \(model)")
            expect(model.uuid(.lifecycle) == "6cd6c8b5-e378-\(part)-030b-1b9740683449", "lifecycle characteristic for \(model)")
        }
        for model in [HiloModel.hilo, .hiloPlus] {
            expect(model.presets.map(HiloProtocol.setProfile) == [bytes("030000"), bytes("030001"), bytes("030002")], "original presets")
        }
        for model in [HiloModel.hilo15, .hiloPlus15] {
            expect(model.presets.map(HiloProtocol.setProfile) == [bytes("030000"), bytes("030001"), bytes("030110"), bytes("030111")], "1.5 presets")
        }
        expect(HiloProtocol.queryProfile == bytes("00"), "read assigned profiles")
        expect(HiloProtocol.queryProfileIndexes == bytes("01"), "read available profiles")
        expect(HiloProtocol.profileReply(bytes("0000020110")) == .assigned(.init(standard: 2, boost: 16)), "assigned response")
        expect(HiloProtocol.profileReply(bytes("0100010210ff")) == .indexes([0, 1, 2, 16]), "index list response")
        expect(HiloProtocol.profileReply(bytes("01ff")) == .indexes([]), "empty index list")
        expect(HiloProtocol.profileReply(bytes("01000102")) == nil, "truncated index list")
        expect(HiloProtocol.profileReply(bytes("03beef")) == .result(accepted: true), "acknowledgment")
        expect(HiloProtocol.profileReply(bytes("03efbe")) == .result(accepted: false), "big-endian acknowledgment")
        expect(HiloProtocol.profileReply(bytes("0300")) == nil, "short acknowledgment")

        let record = bytes("0000000c 691aae80 00f0 0001 01 10 0000 0000 01")
        let decoded = SessionRecord(sequence: 12, timestamp: 0x691aae80, duration: 240, exitCode: 1, mode: .boost)
        for model in HiloModel.allCases {
            expect(HiloProtocol.historyPacket(bytes("0012"), model: model) == .count(18), "record count")
            expect(HiloProtocol.historyPacket(bytes("fffffffe00000012"), model: model) == .start(18), "start marker")
            expect(HiloProtocol.historyPacket(bytes("fffffffd"), model: model) == .end, "end marker")
            expect(HiloProtocol.historyPacket(bytes("ffffffff"), model: model) == nil, "unknown marker")
            expect(HiloProtocol.historyPacket(record, model: model) == .records([decoded]), "single record")
            let batch = bytes("05") + record + record
            expect(HiloProtocol.historyPacket(batch, model: model) == (model.is15 ? .records([decoded, decoded]) : nil), "version-5 framed batch")
            expect(HiloProtocol.historyPacket(batch.dropLast(), model: model) == nil, "truncated batch")
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let offset = HiloProtocol.clockOffset(bytes("00000064"), now: now)
        let relative = SessionRecord(sequence: 13, timestamp: 30, duration: 120, exitCode: 0, mode: .standard)
        expect(relative.date(offset: nil, now: now) == nil, "unknown clock")
        expect(relative.date(offset: offset, now: now) == now.addingTimeInterval(-70), "relative clock")
        expect(decoded.date(offset: offset, now: now)?.timeIntervalSince1970 == Double(decoded.timestamp), "absolute clock")

        var info = Data(repeating: 0, count: 50)
        info.replaceSubrange(0..<4, with: bytes("01020304"))
        info.replaceSubrange(6..<22, with: Data(repeating: 3, count: 16))
        expect(HiloDeviceInfo(info, model: .hilo)?.firmware == "1.2.772", "firmware version")
        let base = try required(HiloDeviceInfo(info, model: .hilo)?.historySource, "base identity")
        expect(HiloDeviceInfo(info, model: .hiloPlus)?.historySource == nil, "missing pen")
        info.replaceSubrange(30..<46, with: Data(repeating: 4, count: 16))
        let pen = try required(HiloDeviceInfo(info, model: .hiloPlus)?.historySource, "pen identity")
        expect(base.id != pen.id, "separate device and pen")
        info.replaceSubrange(6..<22, with: Data(repeating: 5, count: 16))
        expect(HiloDeviceInfo(info, model: .hiloPlus15)?.historySource?.id == pen.id, "pen moved to another box")
        expect(SessionState(bytes("000001"), model: .hiloPlus)?.penPresent == true, "pen inserted")
        expect(SessionState(bytes("010000"), model: .hiloPlus)?.isActive == true, "active session")
        expect(SessionState(bytes("00"), model: .hiloPlus) == nil, "truncated pen status")
        expect(SessionState(bytes("00000101"), model: .hiloPlus)?.endWarningEnabled == true, "Plus end-warning status")
        expect(SessionState(bytes("00000100"), model: .hiloPlus15)?.endWarningEnabled == false, "Plus 1.5 end-warning status")
        expect(SessionState(bytes("000001"), model: .hilo)?.endWarningEnabled == true, "Hilo end-warning status")
        expect(SessionState(bytes("0000ff"), model: .hilo15)?.endWarningEnabled == nil, "undefined end-warning status")
        expect(DeviceSetting.endWarning.writeValue(0) == bytes("0100"), "end-warning off command")
        expect(DeviceSetting.endWarning.writeValue(1) == bytes("0101"), "end-warning on command")
        expect(DeviceSetting.endWarning.writeValue(2) == nil, "invalid end-warning bit")
        expect(DeviceSetting.brightness.writeValue(100) == bytes("64"), "maximum brightness command")
        expect(DeviceSetting.brightness.writeValue(101) == nil, "out-of-range brightness")
        expect(DeviceSetting.brightness.readValue(bytes("643232")) == 50, "extended brightness reply")
        expect(DeviceSetting.brightness.readValue(bytes("6432")) == nil, "truncated brightness reply")
        expect(DeviceSetting.buzzer.readValue(bytes("02")) == 2, "buzzer readback")
        expect(DeviceSetting.buzzer.writeValue(3) == nil, "out-of-range buzzer")

        let fault = bytes("691aae80 1234 691aae81 00ab")
        expect(HiloLastError(fault, model: .hiloPlus)?.code == 0x1234, "case error code")
        expect(HiloLastError(fault, model: .hiloPlus)?.penCode == 0x00ab, "pen error code")
        expect(HiloLastError(fault.prefix(6), model: .hiloPlus) == nil, "truncated Plus fault")
        expect(HiloLastError(fault.prefix(6), model: .hilo)?.penCode == nil, "single-device fault")

        let penCounters = bytes("fffb 001e 0c80 1068 0000 0000 0000002a 00000005 00000021 00000008 0000 0000")
        let caseCounters = bytes("fff6 0028 0bb8 1068 0000 0000 0000000c 00000003 000003e8")
        let lifecycle = try required(HiloLifecycle(penCounters + caseCounters, model: .hiloPlus), "Plus lifecycle response")
        expect(HiloProtocol.queryLifecycle == bytes("01"), "read all lifecycle fields")
        expect(lifecycle.pen?.minimumBatteryTemperature == -5, "signed pen temperature")
        expect(lifecycle.pen?.maximumBatteryVoltage == 4200, "pen battery voltage")
        expect(lifecycle.pen?.fullCharges == 5, "pen full-charge count")
        expect(lifecycle.pen?.completedSessions == 33 && lifecycle.pen?.incompleteSessions == 8, "pen session counters")
        expect(lifecycle.main.minimumBatteryTemperature == -10 && lifecycle.main.fullCharges == 3, "charger fields begin at byte 32")
        expect(lifecycle.main.completedSessions == nil, "charger has no session count")
        expect(HiloLifecycle(penCounters, model: .hilo)?.main.completedSessions == 33, "Hilo lifecycle counts")
        expect(HiloLifecycle((penCounters + caseCounters).dropLast(), model: .hiloPlus) == nil, "truncated lifecycle response")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let empty = try store.load()
        expect(empty.sessions.isEmpty, "empty store")
        let first = UsageSession(source: base, sequence: 12, deviceTimestamp: decoded.timestamp, date: now, mode: .boost)
        let second = UsageSession(source: pen, sequence: 12, deviceTimestamp: decoded.timestamp, date: now, mode: .boost)
        let merged = store.merging([first, first, second], into: empty, at: now)
        try store.save(merged)
        let restored = try store.load()
        expect(restored.sessions.map(\.id) == [first.id, second.id], "save and deduplicate per pen")
        expect(store.merging([first, second], into: restored, at: now).sessions.count == 2, "idempotent sync")
        print("Protocol checks passed for Hilo and Hilo Plus (four service profiles).")
    }

    private static func bytes(_ hex: String) -> Data {
        let characters = Array(hex.filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...$0 + 1]), radix: 16)!
        })
    }

    private static func expect(_ check: @autoclosure () -> Bool, _ message: String) {
        precondition(check(), message)
    }

    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: message, code: 1) }
        return value
    }
}
