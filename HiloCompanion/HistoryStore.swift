import Foundation

struct HistorySource: Codable, Hashable, Identifiable {
    let id: String
    let label: String
}

struct UsageSession: Codable, Identifiable {
    let source: HistorySource
    let sequence: UInt32
    let deviceTimestamp: UInt32
    let date: Date
    let mode: HeatingMode?

    var id: String { "\(source.id):\(sequence):\(deviceTimestamp)" }
}

struct UsageHistory: Codable {
    var sessions: [UsageSession] = []
    var lastSync: Date?
}

struct HistoryStore {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory
            .appendingPathComponent("HiloCompanion", isDirectory: true)
    }

    private var file: URL { directory.appendingPathComponent("usage.json") }

    func load() throws -> UsageHistory {
        do {
            return try JSONDecoder().decode(UsageHistory.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return UsageHistory()
        }
    }

    func save(_ history: UsageHistory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var localDirectory = directory
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try localDirectory.setResourceValues(flags)
        try JSONEncoder().encode(history).write(to: file, options: .atomic)
    }

    func merging(_ sessions: [UsageSession], into history: UsageHistory, at date: Date) -> UsageHistory {
        var update = history
        var known = Set(history.sessions.map(\.id))
        update.sessions += sessions.filter { known.insert($0.id).inserted }
        update.lastSync = date
        return update
    }
}
