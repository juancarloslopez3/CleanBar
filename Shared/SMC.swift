@preconcurrency import Darwin
import Foundation
import IOKit

/// The Mac's System Management Controller, which has its temperature sensors and runs its fans. It's reached through the
/// AppleSMC driver, by keys of four characters. Apple doesn't document any of it: what the keys mean is what people have
/// worked out over the years.
///
/// Anyone can read a key. Only root can write one (others get `kIOReturnNotPrivileged`, seen on macOS 27.2), which is why
/// CleanBar has a helper for changing the fans. Not thread-safe.
nonisolated final class SMC {
    /// What the driver takes and gives back, for every command.
    private struct Parameters {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16, UInt16) = (0, 0, 0, 0, 0, 0)
        var powerLimits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var size: UInt32 = 0
        var type: UInt32 = 0
        var attributes: UInt8 = 0
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var padding2: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case read = 5
        case write = 6
        case keyInfo = 9
    }

    private struct KeyInfo {
        let size: UInt32
        let type: UInt32
    }

    /// The driver's only method for this, `kSMCHandleYPCEvent`.
    private static let handleEvent: UInt32 = 2
    private static let floatType = code("flt ")
    private static let byteType = code("ui8 ")

    private let connection: io_connect_t
    /// The keys looked up so far, nil for those that don't exist.
    private var infos: [String: KeyInfo?] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    func has(_ key: String) -> Bool {
        info(key) != nil
    }

    /// A key that holds a number in the format Apple silicon uses, a 32-bit float.
    func float(_ key: String) -> Double? {
        guard let info = info(key), info.type == Self.floatType, let bytes = read(key, info), bytes.count == 4 else { return nil }
        return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    }

    func byte(_ key: String) -> UInt8? {
        guard let info = info(key), info.type == Self.byteType, let bytes = read(key, info), bytes.count == 1 else { return nil }
        return bytes[0]
    }

    /// Takes root. Returns whether the SMC took the value.
    func write(_ key: String, float value: Double) -> Bool {
        guard let info = info(key), info.type == Self.floatType else { return false }
        return write(key, info, withUnsafeBytes(of: Float(value)) { Array($0) })
    }

    /// Takes root. Returns whether the SMC took the value.
    func write(_ key: String, byte value: UInt8) -> Bool {
        guard let info = info(key), info.type == Self.byteType else { return false }
        return write(key, info, [value])
    }

    private func info(_ key: String) -> KeyInfo? {
        if let known = infos[key] {
            return known
        }
        var input = Parameters()
        input.key = Self.code(key)
        input.command = Command.keyInfo.rawValue
        let info = call(&input).map { KeyInfo(size: $0.size, type: $0.type) }
        infos[key] = .some(info)
        return info
    }

    private func read(_ key: String, _ info: KeyInfo) -> [UInt8]? {
        var input = Parameters()
        input.key = Self.code(key)
        input.size = info.size
        input.type = info.type
        input.command = Command.read.rawValue
        guard var output = call(&input) else { return nil }
        return withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(info.size))) }
    }

    private func write(_ key: String, _ info: KeyInfo, _ value: [UInt8]) -> Bool {
        guard value.count == Int(info.size) else { return false }
        var input = Parameters()
        input.key = Self.code(key)
        input.size = info.size
        input.type = info.type
        input.command = Command.write.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { $0.copyBytes(from: value) }
        return call(&input) != nil
    }

    private func call(_ input: inout Parameters) -> Parameters? {
        var output = Parameters()
        var outputSize = MemoryLayout<Parameters>.stride
        let result = IOConnectCallStructMethod(connection, Self.handleEvent, &input, MemoryLayout<Parameters>.stride, &output, &outputSize)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private static func code(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

nonisolated extension SMC {
    var fanCount: Int {
        Int(byte("FNum") ?? 0)
    }

    /// The key that says who runs a fan: 1 means it holds the speed it's given. Other values mean macOS runs it, and
    /// which ones differs between chips. Spelled differently from M5 on.
    func fanModeKey(_ fan: Int) -> String? {
        ["F\(fan)Md", "F\(fan)md"].first(where: has)
    }
}
