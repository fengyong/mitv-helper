import Foundation
import SQLite3

/// SQLITE_TRANSIENT 是 C 宏，Swift overlay 不导出——按惯例自构造（-1 = sqlite3 自拷贝绑定值）
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 缩略图磁盘缓存索引（SQLite，用户需求：md5 记录对应缩略图，免每次重复下载/解析）。
/// - 查询主键 = 远端路径 + 文件大小（下载前可知；size 变化 = 内容已变 → 自动失效）
/// - digest 列记录内容前缀 md5（下载完成后填充，供将来内容寻址场景使用；无法作查询键）
/// - 缩略图文件本体持久化在 Thumbs 目录，重启 App 后仍命中
final class ThumbCacheStore {

    private var db: OpaquePointer?
    private let lock = NSLock()
    /// 记录数上限：超过则按创建时间剪到一半（缩略图文件一并删除）
    private let maxEntries: Int

    init(directory: URL, maxEntries: Int = 2000) {
        self.maxEntries = max(4, maxEntries)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let url = directory.appendingPathComponent("thumbs.db")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil
            return
        }
        exec("CREATE TABLE IF NOT EXISTS thumbs (path TEXT PRIMARY KEY, size INTEGER NOT NULL, digest TEXT, file TEXT NOT NULL, created_at REAL NOT NULL)")
        exec("CREATE INDEX IF NOT EXISTS idx_thumbs_created ON thumbs(created_at)")
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// 查询：path+size 均匹配返回缩略图文件名（相对缓存目录），否则 nil
    func lookup(path: String, size: Int64) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT file FROM thumbs WHERE path = ? AND size = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, size)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    /// 写入/更新（同 path 覆盖）；返回落盘应使用的缩略图文件名
    func store(path: String, size: Int64, digest: String?, file: String) {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO thumbs (path, size, digest, file, created_at) VALUES (?, ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, size)
        if let d = digest, !d.isEmpty {
            sqlite3_bind_text(stmt, 3, d, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, file, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
        pruneLocked()
    }

    /// 删除一条记录（缓存文件丢失等场景）；返回被删记录的缩略图文件名
    @discardableResult
    func delete(path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return nil }
        var file: String?
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT file FROM thumbs WHERE path = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                file = String(cString: c)
            }
        }
        sqlite3_finalize(stmt)
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM thumbs WHERE path = ?", -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_text(del, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_step(del)
        }
        sqlite3_finalize(del)
        return file
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return countLocked()
    }

    /// 持锁版（store 内不可重入调用，NSLock 非递归——曾因此死锁挂死测试）
    private func countLocked() -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM thumbs", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 超上限：按 created_at 删最旧的一半（连带缩略图文件）。内部持锁版供 store 调用
    private func pruneLocked() -> [String] {
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM thumbs", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [] }
        let count = Int(sqlite3_column_int64(stmt, 0))
        guard count > maxEntries else { return [] }
        let excess = count - maxEntries / 2
        var files: [String] = []
        var sel: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT file FROM thumbs ORDER BY created_at ASC LIMIT \(excess)", -1, &sel, nil) == SQLITE_OK {
            while sqlite3_step(sel) == SQLITE_ROW, let c = sqlite3_column_text(sel, 0) {
                files.append(String(cString: c))
            }
        }
        sqlite3_finalize(sel)
        if !files.isEmpty {
            exec("DELETE FROM thumbs WHERE file IN (\(files.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: ",")))")
        }
        return files
    }
}
