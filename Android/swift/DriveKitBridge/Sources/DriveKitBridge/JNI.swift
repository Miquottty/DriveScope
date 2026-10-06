import CJNI

/// Java ⇄ Swift values for the JNI entry points.
extension UnsafeMutablePointer where Pointee == JNIEnv? {
    var functions: JNINativeInterface { pointee!.pointee }

    func string(_ value: jstring?) -> String {
        guard let value, let chars = functions.GetStringUTFChars(self, value, nil) else { return "" }
        defer { functions.ReleaseStringUTFChars(self, value, chars) }
        return String(cString: chars)
    }

    func jstring(_ value: String) -> CJNI.jstring? {
        value.withCString { functions.NewStringUTF(self, $0) }
    }

    func doubleArray(_ values: [Double]) -> jdoubleArray? {
        guard let array = functions.NewDoubleArray(self, jsize(values.count)) else { return nil }
        values.withUnsafeBufferPointer { functions.SetDoubleArrayRegion(self, array, 0, jsize(values.count), $0.baseAddress) }
        return array
    }

    func floats(_ array: jfloatArray?) -> [Float] {
        guard let array else { return [] }
        let count = Int(functions.GetArrayLength(self, array))
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBufferPointer { functions.GetFloatArrayRegion(self, array, 0, jsize(count), $0.baseAddress) }
        return values
    }
}
