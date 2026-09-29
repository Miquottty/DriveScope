/// Float32 3-vector used for stored motion data.
public struct Vector3: Sendable, Equatable, Codable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)

    public var length: Float { (x * x + y * y + z * z).squareRoot() }

    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    public static func * (a: Vector3, s: Float) -> Vector3 { Vector3(x: a.x * s, y: a.y * s, z: a.z * s) }

    public func dot(_ o: Vector3) -> Float { x * o.x + y * o.y + z * o.z }

    func write(to w: inout RecordWriter) {
        w.put(x); w.put(y); w.put(z)
    }

    init(reading r: inout RecordReader) {
        x = r.float(); y = r.float(); z = r.float()
    }
}

/// Unit quaternion (w, x, y, z) for `CMAttitude`.
public struct Quaternion: Sendable, Equatable, Codable {
    public var w: Float
    public var x: Float
    public var y: Float
    public var z: Float

    public init(w: Float, x: Float, y: Float, z: Float) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)
}
