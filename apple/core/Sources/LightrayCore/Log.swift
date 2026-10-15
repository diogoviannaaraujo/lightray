import Foundation

private let started = Date()

/// A line on standard error, stamped with seconds since launch.
public func log(_ message: String) {
    let elapsed = String(format: "%8.3f", Date().timeIntervalSince(started))
    FileHandle.standardError.write(Data("[\(elapsed)] \(message)\n".utf8))
}
