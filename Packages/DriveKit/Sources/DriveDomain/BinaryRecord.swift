/// A fixed-size, little-endian record stored in an append-only `.bin` stream (PLAN §4.1).
///
/// Layouts are hand-packed (no padding, no `MemoryLayout` dependence) so files stay readable
/// across compiler versions and on other tools. Changing a layout requires bumping `formatVersion`.
public protocol BinaryRecord: Sendable {
    static var recordSize: Int { get }
    static var formatVersion: UInt16 { get }
    /// Writes exactly `recordSize` bytes starting at `offset`.
    func encode(into buffer: UnsafeMutableRawBufferPointer, at offset: Int)
    /// Reads a record from exactly `recordSize` bytes starting at `offset`.
    init(decoding buffer: UnsafeRawBufferPointer, at offset: Int)
}

extension BinaryRecord {
    public static var formatVersion: UInt16 { 1 }

    public func encoded() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.recordSize)
        bytes.withUnsafeMutableBytes { encode(into: $0, at: 0) }
        return bytes
    }
}

/// Sequential little-endian writer over a raw buffer.
public struct RecordWriter {
    private let buffer: UnsafeMutableRawBufferPointer
    public private(set) var offset: Int

    public init(_ buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        self.buffer = buffer
        self.offset = offset
    }

    public mutating func put<T: FixedWidthInteger>(_ value: T) {
        buffer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
        offset += MemoryLayout<T>.size
    }

    public mutating func put(_ value: Double) { put(value.bitPattern) }
    public mutating func put(_ value: Float) { put(value.bitPattern) }
}

/// Sequential little-endian reader over a raw buffer.
public struct RecordReader {
    private let buffer: UnsafeRawBufferPointer
    public private(set) var offset: Int

    public init(_ buffer: UnsafeRawBufferPointer, at offset: Int) {
        self.buffer = buffer
        self.offset = offset
    }

    public mutating func get<T: FixedWidthInteger>(_: T.Type = T.self) -> T {
        let raw = buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += MemoryLayout<T>.size
        return T(littleEndian: raw)
    }

    public mutating func double() -> Double { Double(bitPattern: get(UInt64.self)) }
    public mutating func float() -> Float { Float(bitPattern: get(UInt32.self)) }
}
