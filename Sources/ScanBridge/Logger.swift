import os

extension Logger {
    static let scanner = Logger(subsystem: "ScanBridge", category: "Scanner")
    static let simulatorHost = Logger(subsystem: "ScanBridge", category: "SimulatorHost")
}
