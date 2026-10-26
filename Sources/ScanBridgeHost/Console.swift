import Foundation

/// Minimal console output for the host tool. Thread safe.
enum Console {
    private static let lock = NSLock()

    static func info(_ message: String) {
        write(message, to: FileHandle.standardOutput)
    }

    static func error(_ message: String) {
        write("error: \(message)", to: FileHandle.standardError)
    }

    private static func write(_ message: String, to handle: FileHandle) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        lock.withLock {
            handle.write(Data("[\(time)] \(message)\n".utf8))
        }
    }
}
