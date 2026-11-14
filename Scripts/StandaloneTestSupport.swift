// Assertion adapter for Command Line Tools installations without XCTest.
// The actual test bodies are shared with the native XCTest target.
import Foundation

class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
enum StandaloneTests {
    static var failures = 0
    static var count = 0
    static func fail(_ message: String, file: StaticString, line: UInt) {
        failures += 1; print("FAIL \(file):\(line): \(message)")
    }
    static func run(_ name: String, test: XCTestCase, body: () throws -> Void) {
        count += 1
        let before = failures
        do { try test.setUpWithError(); try body() }
        catch { fail("\(name): \(error)", file: #filePath, line: #line) }
        do { try test.tearDownWithError() }
        catch { fail("\(name) teardown: \(error)", file: #filePath, line: #line) }
        print("\(failures == before ? "PASS" : "FAIL") \(name)")
    }
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { StandaloneTests.fail("Expected true", file: file, line: line) } }
    catch { StandaloneTests.fail("\(error)", file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(try !value(), file: file, line: line)
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { let a = try lhs(), b = try rhs(); if a != b { StandaloneTests.fail("\(a) != \(b)", file: file, line: line) } }
    catch { StandaloneTests.fail("\(error)", file: file, line: line) }
}
func XCTAssertEqual<T: Numeric & Comparable>(_ a: T, _ b: T, accuracy: T, file: StaticString = #filePath, line: UInt = #line) {
    if (a > b ? a - b : b - a) > accuracy { StandaloneTests.fail("\(a) != \(b) ± \(accuracy)", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a != b, file: file, line: line) }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value == nil, file: file, line: line) }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a > b, file: file, line: line) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); StandaloneTests.fail("Expected error", file: file, line: line) } catch {}
}
func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { StandaloneTests.fail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw NSError(domain: "TestUnwrap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nil at \(file):\(line)"]) }
    return value
}
