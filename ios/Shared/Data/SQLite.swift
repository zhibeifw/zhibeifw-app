import Foundation
import SQLite3

/// SQLite 的值。所有带输入的语句一律参数绑定。
enum SQLValue: Equatable {
    case int(Int64), double(Double), text(String), null
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    init(stringLiteral v: String) { self = .text(v) }
    init(integerLiteral v: Int) { self = .int(Int64(v)) }
    init(floatLiteral v: Double) { self = .double(v) }
    init(nilLiteral: ()) { self = .null }
}

protocol SQLConvertible { var sql: SQLValue { get } }
extension String: SQLConvertible { var sql: SQLValue { .text(self) } }
extension Int: SQLConvertible { var sql: SQLValue { .int(Int64(self)) } }
extension Int64: SQLConvertible { var sql: SQLValue { .int(self) } }
extension Double: SQLConvertible { var sql: SQLValue { .double(self) } }
extension Bool: SQLConvertible { var sql: SQLValue { .int(self ? 1 : 0) } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible { var sql: SQLValue { self?.sql ?? .null } }
extension SQLValue: SQLConvertible { var sql: SQLValue { self } }

struct Row {
    let values: [String: SQLValue]
    func str(_ k: String) -> String { if case .text(let s)? = values[k] { return s }; return optStr(k) ?? "" }
    func optStr(_ k: String) -> String? {
        switch values[k] {
        case .text(let s)?: return s
        case .int(let i)?: return String(i)
        case .double(let d)?: return String(d)
        default: return nil
        }
    }
    func int(_ k: String) -> Int64 { optInt(k) ?? 0 }
    func optInt(_ k: String) -> Int64? {
        switch values[k] {
        case .int(let i)?: return i
        case .double(let d)?: return d.isFinite ? Int64(exactly: d.rounded(.towardZero)) : nil  // 无穷大、NaN、超范围返回 nil，不让进程中止
        case .text(let s)?: return Int64(s)
        default: return nil
        }
    }
    func double(_ k: String) -> Double { optDouble(k) ?? 0 }
    func optDouble(_ k: String) -> Double? {
        switch values[k] {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        case .text(let s)?: return Double(s)
        default: return nil
        }
    }
    func bool(_ k: String) -> Bool { int(k) != 0 }
}

struct SQLError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 系统自带 SQLite3 的一层薄包装。写连接一个，一把递归锁：同一时间只有一个线程在用。
/// 另有一个只读连接（WAL 模式下读写互不阻塞）：写连接被别的线程占着（比如后台写目录的事务）时，读查询走它，
/// 不用排队等事务做完；读到的是最近一次提交的内容。
final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var reader: OpaquePointer?
    private var readerTried = false
    private let readLock = NSLock()
    let path: String

    /// readOnly：只读打开（读 v1.0 的旧库），不改文件、不切 WAL
    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        var h: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开"
            sqlite3_close(h)
            throw SQLError(code: rc, message: msg)
        }
        db = h
        sqlite3_busy_timeout(h, 5000)
        if !readOnly { try exec("PRAGMA journal_mode = WAL;") }
    }

    deinit {
        sqlite3_close_v2(reader)
        sqlite3_close_v2(db)
    }

    private func err(_ rc: Int32, _ h: OpaquePointer? = nil) -> SQLError {
        SQLError(code: rc, message: String(cString: sqlite3_errmsg(h ?? db)))
    }

    /// 只读连接，第一次用时打开；打不开（比如内存库）就不用，读查询照旧排队用写连接。调用方持有 readLock。
    private func readerHandle() -> OpaquePointer? {
        if readerTried { return reader }
        readerTried = true
        guard !path.isEmpty, path != ":memory:" else { return nil }
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
            sqlite3_close(h)
            return nil
        }
        sqlite3_busy_timeout(h, 5000)
        guard sqlite3_exec(h, "PRAGMA query_only = 1", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(h)
            return nil
        }
        reader = h
        return h
    }

    /// 只用于固定语句（建表、迁移），绝不拼接外部输入。
    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var msg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &msg)
        if rc != SQLITE_OK {
            let m = msg.map { String(cString: $0) } ?? ""
            sqlite3_free(msg)
            throw SQLError(code: rc, message: m)
        }
    }

    private func prepare(_ sql: String, _ args: [SQLConvertible], on h: OpaquePointer? = nil) throws -> OpaquePointer {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(h ?? db, sql, -1, &st, nil)
        guard rc == SQLITE_OK, let st else { throw err(rc, h) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a.sql {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .double(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }

    /// 执行一条带参数的语句。返回受影响的行数。
    @discardableResult
    func run(_ sql: String, _ args: [SQLConvertible] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW { rc = sqlite3_step(st) }
        guard rc == SQLITE_DONE else { throw err(rc) }
        return Int(sqlite3_changes(db))
    }

    func all(_ sql: String, _ args: [SQLConvertible] = []) throws -> [Row] {
        // 写连接空着（或者就是本线程在事务里，要读到自己还没提交的写入）：用写连接
        if lock.try() {
            defer { lock.unlock() }
            return try query(sql, args, on: db)
        }
        readLock.lock()
        if let r = readerHandle() {
            defer { readLock.unlock() }
            return try query(sql, args, on: r)
        }
        readLock.unlock()
        lock.lock(); defer { lock.unlock() }
        return try query(sql, args, on: db)
    }

    private func query(_ sql: String, _ args: [SQLConvertible], on h: OpaquePointer?) throws -> [Row] {
        let st = try prepare(sql, args, on: h)
        defer { sqlite3_finalize(st) }
        var rows: [Row] = []
        let n = sqlite3_column_count(st)
        var names: [String] = []
        // 内存不足时可能拿到空指针，直接转字符串会崩
        for i in 0..<n { names.append(sqlite3_column_name(st, i).map { String(cString: $0) } ?? "") }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw err(rc, h) }
            var v: [String: SQLValue] = [:]
            for i in 0..<n {
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: v[names[Int(i)]] = .int(sqlite3_column_int64(st, i))
                case SQLITE_FLOAT: v[names[Int(i)]] = .double(sqlite3_column_double(st, i))
                case SQLITE_NULL: v[names[Int(i)]] = .null
                default:
                    // 取文本失败（内存不足等）时是空指针，不能直接转字符串
                    if let p = sqlite3_column_text(st, i) { v[names[Int(i)]] = .text(String(cString: p)) } else { v[names[Int(i)]] = .null }
                }
            }
            rows.append(Row(values: v))
        }
        return rows
    }

    func first(_ sql: String, _ args: [SQLConvertible] = []) throws -> Row? { try all(sql, args).first }

    /// 事务：中途抛错整体回滚。可以嵌套调用（内层直接执行，外层负责提交）。
    private var depth = 0
    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if depth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE")
        depth += 1
        defer { depth -= 1 }  // 只减一次：提交失败走到下面的回滚也一样
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { Int((try? first("PRAGMA user_version"))?.int("user_version") ?? 0) }
    }
    func setUserVersion(_ v: Int) throws { try exec("PRAGMA user_version = \(v)") }  // 固定的整数，不含外部数据
}
