import Foundation
import SQLite3

/// What the temperature sensors and the fans read over the last month, in a small database in CleanBar's Application Support
/// folder.
///
/// Each `HistoryRange` has its own samples, each one the average of what was read while it lasted, so the database stays
/// about a megabyte however long it runs. Readings wait in memory for a couple of minutes and go in together, which keeps
/// writes to the disk down. The rows of a moment are next to each other in the file, so saving them touches few pages. The
/// Mac being asleep or CleanBar being closed leaves gaps, which the chart shows as such.
nonisolated final class SensorHistory: @unchecked Sendable {
    private struct Sample: Hashable {
        let range: HistoryRange
        /// Seconds since 1970 that it starts at.
        let start: Int
        let sensor: String
    }

    private static let saveInterval: TimeInterval = 120
    private static let pruneInterval: TimeInterval = 3600

    /// Everything here goes through this queue.
    private let queue = DispatchQueue(label: "CleanBar sensor history", qos: .utility)
    private let fileURL: URL?
    private var database: OpaquePointer?
    private var isOpen = false
    /// What was read since the last save.
    private var unsaved: [Sample: (total: Double, count: Int)] = [:]
    private var lastSave = Date.distantPast
    private var lastPrune = Date.distantPast

    /// The file it's kept in. In `Application Support` rather than `Caches`, where macOS could throw it away.
    private static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: Bundle.main.bundleIdentifier ?? "CleanBar")
            .appending(path: "SensorHistory.sqlite")
    }

    init(fileURL: URL? = SensorHistory.defaultFileURL) {
        self.fileURL = fileURL
    }

    deinit {
        sqlite3_close(database)
    }

    /// Adds what the sensors and fans read now, by `SensorRow.id`.
    func record(_ readings: [String: Double], at date: Date = .now) {
        queue.async { [self] in
            let now = Int(date.timeIntervalSince1970)
            for range in HistoryRange.allCases {
                let start = now - now % range.sampleLength
                for (sensor, reading) in readings {
                    let sample = Sample(range: range, start: start, sensor: sensor)
                    let waiting = unsaved[sample] ?? (0, 0)
                    unsaved[sample] = (waiting.total + reading, waiting.count + 1)
                }
            }
            if date.timeIntervalSince(lastSave) >= Self.saveInterval {
                saveNow(at: date)
            }
        }
    }

    /// The samples over `range` of a sensor or a fan, by `SensorRow.id`, oldest first.
    func points(of sensor: String, in range: HistoryRange, at date: Date = .now) async -> [HistoryPoint] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                saveNow(at: date)
                continuation.resume(returning: readPoints(of: sensor, in: range, at: date))
            }
        }
    }

    /// Saves what's waiting, and returns once it has: for when CleanBar quits or the Mac sleeps.
    func save() {
        queue.sync { saveNow(at: .now) }
    }

    // MARK: The database

    private func open() -> OpaquePointer? {
        if isOpen { return database }
        isOpen = true
        guard let fileURL else { return nil }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(fileURL.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            return nil
        }
        let setUp = """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS samples (
                range INTEGER NOT NULL,
                start INTEGER NOT NULL,
                sensor TEXT NOT NULL,
                total REAL NOT NULL,
                count INTEGER NOT NULL,
                PRIMARY KEY (range, start, sensor)
            ) WITHOUT ROWID;
            """
        if sqlite3_exec(database, setUp, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(database)
            database = nil
        }
        return database
    }

    /// Readings add to what's there, so a sample that was already started before CleanBar restarted carries on.
    private func saveNow(at date: Date) {
        lastSave = date
        guard !unsaved.isEmpty, let database = open() else { return }
        let insert = """
            INSERT INTO samples (range, start, sensor, total, count) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (range, start, sensor) DO UPDATE SET total = total + excluded.total, count = count + excluded.count
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_exec(database, "BEGIN", nil, nil, nil)
        for (sample, reading) in unsaved {
            sqlite3_bind_int(statement, 1, Int32(sample.range.rawValue))
            sqlite3_bind_int64(statement, 2, Int64(sample.start))
            sqlite3_bind_text(statement, 3, sample.sensor, -1, transient)
            sqlite3_bind_double(statement, 4, reading.total)
            sqlite3_bind_int64(statement, 5, Int64(reading.count))
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
        sqlite3_exec(database, "COMMIT", nil, nil, nil)
        unsaved.removeAll(keepingCapacity: true)
        if date.timeIntervalSince(lastPrune) >= Self.pruneInterval {
            prune(database, at: date)
        }
    }

    /// Takes out each range's samples that have gone out of it.
    private func prune(_ database: OpaquePointer, at date: Date) {
        lastPrune = date
        let now = Int(date.timeIntervalSince1970)
        for range in HistoryRange.allCases {
            let oldest = now - range.duration - range.sampleLength
            sqlite3_exec(database, "DELETE FROM samples WHERE range = \(range.rawValue) AND start < \(oldest)", nil, nil, nil)
        }
    }

    private func readPoints(of sensor: String, in range: HistoryRange, at date: Date) -> [HistoryPoint] {
        guard let database = open() else { return [] }
        var statement: OpaquePointer?
        let query = "SELECT start, total / count FROM samples WHERE range = ? AND start >= ? AND sensor = ? ORDER BY start"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(range.rawValue))
        sqlite3_bind_int64(statement, 2, Int64(date.timeIntervalSince1970) - Int64(range.duration))
        sqlite3_bind_text(statement, 3, sensor, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var points: [HistoryPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            points.append(HistoryPoint(
                date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                value: sqlite3_column_double(statement, 1)
            ))
        }
        return points
    }
}
