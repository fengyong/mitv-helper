// 轻量测试 runner（不用 XCTest：CLT 环境无 XCTest 模块）。
// 规约：每个测试套件是 enum XxxTests { static func run() }，写在独立文件里；
// 新测试 = 新文件 + 在底部 allSuites 数组追加一行（这是唯一允许触碰本文件的地方）。
import Foundation

var _failures = 0
var _cases = 0

func assertTrue(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    _cases += 1
    if !cond { print("❌ FAIL \(msg)  (\(file):\(line))"); _failures += 1 }
}

func assertFalse(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    assertTrue(!cond, msg, file: file, line: line)
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    _cases += 1
    if a != b { print("❌ FAIL \(msg)：\(a) != \(b)  (\(file):\(line))"); _failures += 1 }
}

func assertThrows<T>(_ msg: String, _ body: () throws -> T, file: StaticString = #file, line: UInt = #line) {
    _cases += 1
    do { _ = try body(); print("❌ FAIL \(msg)：未抛错  (\(file):\(line))"); _failures += 1 }
    catch {}
}

func assertNoThrow<T>(_ msg: String, _ body: () throws -> T, file: StaticString = #file, line: UInt = #line) {
    _cases += 1
    do { _ = try body() } catch { print("❌ FAIL \(msg)：\(error)  (\(file):\(line))"); _failures += 1 }
}

// MARK: - 注册与执行（新套件在此追加一行）

let allSuites: [(String, () -> Void)] = [
    ("NameCodecTests", NameCodecTests.run),
    ("EngineTests_A", EngineTests_A.run),
    ("ServiceTests_B", ServiceTests_B.run),
]

for (name, suite) in allSuites {
    print("—— \(name) ——")
    suite()
}

if _failures == 0 {
    print("✅ ALL \(_cases) CHECKS PASSED")
    exit(0)
} else {
    print("❌ \(_failures)/\(_cases) CHECKS FAILED")
    exit(1)
}
