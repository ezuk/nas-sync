import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { "SQLite: \(message)" }
}

/// Minimal SQLite wrapper. Not thread-safe; callers serialize access.
final class SQLiteDatabase {
    private var db: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            throw SQLiteError(message: message)
        }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close(db)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw SQLiteError(message: message)
        }
    }

    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    struct Row {
        fileprivate let values: [String: Value]

        func int(_ key: String) -> Int64? {
            if case .int(let v) = values[key] { return v }
            return nil
        }

        func double(_ key: String) -> Double? {
            switch values[key] {
            case .double(let v): v
            case .int(let v): Double(v)
            default: nil
            }
        }

        func text(_ key: String) -> String? {
            if case .text(let v) = values[key] { return v }
            return nil
        }

        func blob(_ key: String) -> Data? {
            switch values[key] {
            case .blob(let d): d
            case .text(let s): Data(s.utf8)
            default: nil
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [Value?] = []) throws -> Int64 {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
        return sqlite3_last_insert_rowid(db)
    }

    func query(_ sql: String, _ params: [Value?] = []) throws -> [Row] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var values: [String: Value] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, i))
                    if let ptr = sqlite3_column_blob(stmt, i), count > 0 {
                        values[name] = .blob(Data(bytes: ptr, count: count))
                    } else {
                        values[name] = .blob(Data())
                    }
                default: values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [Value?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param ?? .null {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func lastError() -> SQLiteError {
        SQLiteError(message: String(cString: sqlite3_errmsg(db)))
    }
}
