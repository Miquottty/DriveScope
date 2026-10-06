#if !canImport(simd)
// The four simd functions DriveReplay uses, for platforms without Apple's simd module (Android). Apple platforms
// keep the real ones, so their results are unchanged.

public func simd_dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    (a * b).sum()
}

public func simd_length(_ v: SIMD3<Double>) -> Double {
    simd_dot(v, v).squareRoot()
}

public func simd_normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
    v / simd_length(v)
}

public func simd_cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
#endif
