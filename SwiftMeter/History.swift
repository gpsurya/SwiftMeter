import Foundation
import SQLite3
import os.log

// Per-minute usage history backed by raw SQLite (libsqlite3 ships with
// macOS). One row per (minute, ssid, ifname) tuple holds the bytes
// downloaded and uploaded in that minute. Aggregates (today / 7d / 30d /
// lifetime, plus per-SSID and per-interface) are computed via SQL.
//
// We use raw SQLite instead of SwiftData because @Model relies on a
// macro plugin only present in full Xcode — SwiftMeter is built with
// the Command Line Tools' swiftc to keep the no-Xcode promise.

// MARK: - Public types

enum HistoryWindow: String, CaseIterable, Identifiable {
    case today, last7, last30, lifetime
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today:    return "Today"
        case .last7:    return "Last 7 days"
        case .last30:   return "Last 30 days"
        case .lifetime: return "Lifetime"
        }
    }
}

struct HistoryTotals {
    var dl: Int64
    var ul: Int64
    var total: Int64 { dl + ul }
}

struct HourlyTotal: Identifiable {
    let hour: Int   // 0–23
    var dl: Int64
    var ul: Int64
    var id: Int { hour }
}

struct DailyTotal: Identifiable {
    let date: Date  // start-of-day
    var dl: Int64
    var ul: Int64
    var id: Date { date }
    var total: Int64 { dl + ul }
}

struct PivotEntry: Identifiable {
    let key: String      // SSID or ifname
    var dl: Int64
    var ul: Int64
    var id: String { key }
    var total: Int64 { dl + ul }
}

// MARK: - History (singleton, main-actor)

@MainActor
final class History {

    static let shared = History()

    private let log = Logger(subsystem: "com.swiftmeter.app", category: "history")

    private var db: OpaquePointer?

    /// In-memory buffer keyed by (minute, ssid, ifname). Flushed on minute
    /// rollover so SwiftMeter writes to disk at most once per minute.
    private struct BucketKey: Hashable {
        let minute: Date
        let ssid: String?
        let ifname: String?
    }
    private struct Bucket {
        var dl: Int64 = 0
        var ul: Int64 = 0
    }
    private var pending: [BucketKey: Bucket] = [:]
    private var pendingMinute: Date?
    private var lastCompactDate: Date = .distantPast

    private init() {
        openDatabase()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - DB lifecycle

    private func openDatabase() {
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "SwiftMeter", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: "history.sqlite")

            var handle: OpaquePointer?
            if sqlite3_open(url.path, &handle) == SQLITE_OK {
                db = handle
                exec("""
                    CREATE TABLE IF NOT EXISTS samples (
                        minute  INTEGER NOT NULL,
                        ssid    TEXT,
                        ifname  TEXT,
                        dl      INTEGER NOT NULL,
                        ul      INTEGER NOT NULL,
                        PRIMARY KEY (minute, ssid, ifname)
                    ) WITHOUT ROWID;
                """)
                exec("CREATE INDEX IF NOT EXISTS idx_samples_minute ON samples(minute);")
                // Modest tuning: WAL and "normal" sync are fine for
                // append-mostly minute-resolution data.
                exec("PRAGMA journal_mode=WAL;")
                exec("PRAGMA synchronous=NORMAL;")
            } else {
                log.error("sqlite3_open failed: \(String(cString: sqlite3_errmsg(handle)), privacy: .public)")
            }
        } catch {
            log.error("History init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.flatMap { String(cString: $0) } ?? "?"
            log.error("SQL failed: \(sql, privacy: .public) — \(msg, privacy: .public)")
        }
        if let err { sqlite3_free(err) }
        return rc == SQLITE_OK
    }

    // MARK: - Recording

    /// Add a delta sample. NetworkMonitor calls this every second with the
    /// byte delta since the last tick. Buckets flush on minute rollover.
    func record(dlBytes: Int64,
                ulBytes: Int64,
                ssid: String?,
                ifname: String?,
                now: Date = Date()) {
        guard dlBytes >= 0, ulBytes >= 0 else { return }

        let minute = Self.startOfMinute(now)
        if pendingMinute == nil { pendingMinute = minute }
        if let pm = pendingMinute, pm != minute {
            flush()
            pendingMinute = minute
        }

        let cleanSSID   = (ssid?.isEmpty == false && ssid != "--") ? ssid : nil
        let cleanIfname = (ifname?.isEmpty == false && ifname != "--") ? ifname : nil
        let key = BucketKey(minute: minute, ssid: cleanSSID, ifname: cleanIfname)
        var bucket = pending[key] ?? Bucket()
        bucket.dl &+= dlBytes
        bucket.ul &+= ulBytes
        pending[key] = bucket

        if !Calendar.current.isDate(lastCompactDate, inSameDayAs: now) {
            lastCompactDate = now
            compactIfNeeded()
        }
    }

    /// Force-flush the pending buckets. Called from NetworkMonitor on
    /// app-terminate so the last partial minute isn't lost.
    func flushPending() { flush() }

    private func flush() {
        guard let db, !pending.isEmpty else { return }
        let sql = """
            INSERT INTO samples (minute, ssid, ifname, dl, ul)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(minute, ssid, ifname)
            DO UPDATE SET dl = dl + excluded.dl, ul = ul + excluded.ul;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("prepare flush failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (key, bucket) in pending {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, Int64(key.minute.timeIntervalSince1970))
            if let s = key.ssid {
                sqlite3_bind_text(stmt, 2, s, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let i = key.ifname {
                sqlite3_bind_text(stmt, 3, i, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int64(stmt, 4, bucket.dl)
            sqlite3_bind_int64(stmt, 5, bucket.ul)
            if sqlite3_step(stmt) != SQLITE_DONE {
                log.error("flush step failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        pending.removeAll(keepingCapacity: true)
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    // MARK: - Compaction

    private func compactIfNeeded() {
        let days = max(30, AppSettings.shared.historyRetentionDays)
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let ts = Int64(cutoff.timeIntervalSince1970)
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM samples WHERE minute < ?;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, ts)
            if sqlite3_step(stmt) == SQLITE_DONE {
                let n = sqlite3_changes(db)
                if n > 0 {
                    log.info("Compacted \(n, privacy: .public) rows older than \(days, privacy: .public) days.")
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Queries

    func totals(in window: HistoryWindow) -> HistoryTotals {
        let (start, end) = bounds(for: window)
        flush()
        var dl: Int64 = 0
        var ul: Int64 = 0
        eachSample(from: start, to: end) { _, d, u, _, _ in
            dl &+= d; ul &+= u
        }
        return HistoryTotals(dl: dl, ul: ul)
    }

    /// Per-hour totals for "today" — used by the popover bar chart.
    func hourlyToday() -> [HourlyTotal] {
        flush()
        let cal = Calendar.current
        var bins = (0..<24).map { HourlyTotal(hour: $0, dl: 0, ul: 0) }
        let (start, end) = bounds(for: .today)
        eachSample(from: start, to: end) { ts, d, u, _, _ in
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let h = cal.component(.hour, from: date)
            if (0..<24).contains(h) {
                bins[h].dl &+= d
                bins[h].ul &+= u
            }
        }
        return bins
    }

    /// Per-day totals for the last `days` days (oldest first).
    func dailyTotals(lastDays days: Int) -> [DailyTotal] {
        flush()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var byDay: [Date: DailyTotal] = [:]
        for offset in 0..<days {
            let d = cal.date(byAdding: .day, value: offset, to: start) ?? start
            byDay[d] = DailyTotal(date: d, dl: 0, ul: 0)
        }
        eachSample(from: Int64(start.timeIntervalSince1970),
                   to: Int64.max) { ts, d, u, _, _ in
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts)))
            if var entry = byDay[day] {
                entry.dl &+= d; entry.ul &+= u
                byDay[day] = entry
            }
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    func pivotBySSID(in window: HistoryWindow, limit: Int = 8) -> [PivotEntry] {
        pivot(by: .ssid, in: window, limit: limit)
    }

    func pivotByInterface(in window: HistoryWindow, limit: Int = 8) -> [PivotEntry] {
        pivot(by: .ifname, in: window, limit: limit)
    }

    private enum PivotColumn { case ssid, ifname }

    private func pivot(by column: PivotColumn,
                       in window: HistoryWindow,
                       limit: Int) -> [PivotEntry] {
        flush()
        let (start, end) = bounds(for: window)
        var map: [String: PivotEntry] = [:]
        eachSample(from: start, to: end) { _, d, u, ssid, ifname in
            let key: String
            switch column {
            case .ssid:   key = ssid   ?? "—"
            case .ifname: key = ifname ?? "—"
            }
            var e = map[key] ?? PivotEntry(key: key, dl: 0, ul: 0)
            e.dl &+= d
            e.ul &+= u
            map[key] = e
        }
        return map.values.sorted { $0.total > $1.total }.prefix(limit).map { $0 }
    }

    // MARK: - Helpers

    private func bounds(for window: HistoryWindow) -> (Int64, Int64) {
        let cal = Calendar.current
        let now = Date()
        let start: Date
        switch window {
        case .today:    start = cal.startOfDay(for: now)
        case .last7:    start = cal.date(byAdding: .day, value: -7,  to: now) ?? now
        case .last30:   start = cal.date(byAdding: .day, value: -30, to: now) ?? now
        case .lifetime: start = .distantPast
        }
        let s = start == .distantPast ? Int64.min : Int64(start.timeIntervalSince1970)
        return (s, Int64(now.timeIntervalSince1970) + 60)
    }

    /// Walks rows for the half-open range [start, end). Block is called
    /// with (minute_ts, dl, ul, ssid?, ifname?).
    private func eachSample(from start: Int64,
                            to end: Int64,
                            _ body: (Int64, Int64, Int64, String?, String?) -> Void) {
        guard let db else { return }
        let sql = """
            SELECT minute, dl, ul, ssid, ifname
            FROM samples
            WHERE minute >= ? AND minute < ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, start)
        sqlite3_bind_int64(stmt, 2, end)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let dl = sqlite3_column_int64(stmt, 1)
            let ul = sqlite3_column_int64(stmt, 2)
            let ssid: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 3))
            let ifname: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 4))
            body(ts, dl, ul, ssid, ifname)
        }
    }

    private static func startOfMinute(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute],
                                       from: date)
        return cal.date(from: comps) ?? date
    }
}
