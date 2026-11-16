import Foundation

@main
struct ProtocolChecks {
    static func main() throws {
        let uuidParts = ["0205", "0206", "0209", "020a"]
        for (model, part) in zip(HiloModel.allCases, uuidParts) {
            expect(model.serviceID == "6cd6c8b5-e378-\(part)-000a-1b9740683449", "service for \(model)")
            expect(model.uuid(.history) == "6cd6c8b5-e378-\(part)-060a-1b9740683449", "history characteristic for \(model)")
            expect(model.uuid(.heatingProfile) == "6cd6c8b5-e378-\(part)-0c0a-1b9740683449", "profile characteristic for \(model)")
        }
        for model in [HiloModel.hilo, .hiloPlus] {
            expect(model.presets.map(HiloProtocol.setProfile) == [bytes("030000"), bytes("030001"), bytes("030002")], "original presets")
        }
        for model in [HiloModel.hilo15, .hiloPlus15] {
            expect(model.presets.map(HiloProtocol.setProfile) == [bytes("030000"), bytes("030001"), bytes("030110"), bytes("030111")], "1.5 presets")
        }
        expect(HiloProtocol.queryProfile == bytes("00"), "read assigned profiles")
        expect(HiloProtocol.profileReply(bytes("0000020110")) == .assigned(.init(standard: 2, boost: 16)), "assigned response")
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
