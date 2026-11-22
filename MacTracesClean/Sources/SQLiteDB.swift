import Foundation
import SQLite3

/// Values returned by a SQLite query cell.
enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    var string: String? {
        switch self {
        case .text(let s): return s
        case .int(let i):  return String(i)
        case .double(let d): return String(d)
        case .null: return nil
        }
    }
    var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        default:             return nil
        }
    }
    var int: Int64? {
        switch self {
        case .int(let i):    return i
        case .double(let d): return Int64(d)
        default:             return nil
        }
    }
}

enum SQLiteDB {

    /// Open a database read-only and run a SELECT, returning rows.
    static func query(_ path: URL, _ sql: String) -> [[SQLValue]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [[SQLValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cols = sqlite3_column_count(stmt)
            var row: [SQLValue] = []
            row.reserveCapacity(Int(cols))
            for i in 0..<cols {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT:
                    row.append(.double(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(stmt, i) {
                        row.append(.text(String(cString: c)))
                    } else {
                        row.append(.null)
                    }
                default:
                    row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Count rows of a table (read-only). Returns nil if not readable.
    static func count(_ path: URL, table: String) -> Int? {
        let rows = query(path, "SELECT COUNT(*) FROM \(table)")
        return rows.first?.first?.int.map { Int($0) }
    }

    /// Execute write statements on a real DB, then VACUUM. Throws on lock/error.
    static func execute(_ path: URL, _ statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw SQLiteError.message(msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        for stmt in statements {
            if sqlite3_exec(db, stmt, nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                if msg.lowercased().contains("lock") {
                    throw SQLiteError.locked
                }
                throw SQLiteError.message(msg)
            }
        }
        // VACUUM must run outside a transaction; sqlite3_exec auto-commits each call.
        sqlite3_exec(db, "VACUUM", nil, nil, nil)
    }
}

enum SQLiteError: Error {
    case locked
    case message(String)
}
