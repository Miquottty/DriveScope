package com.miquottty.drivescope.recording

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * One append-only `.bin` stream in the iOS format (DriveKit `StreamFormat.swift`): a 32-byte little-endian header
 * — magic "DSBN", four-character stream code, format version, record size, creation time — then fixed-size records.
 */
class StreamWriter(file: File, fourCC: String, private val recordSize: Int, createdAt: Double, version: Int = 1) {
    private val out = BufferedOutputStream(FileOutputStream(file), 64 * 1024)
    private val record = ByteBuffer.allocate(recordSize).order(ByteOrder.LITTLE_ENDIAN)
    var count = 0
        private set

    init {
        val header = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        header.putInt(MAGIC)
        header.putInt(fourCC.fold(0) { acc, c -> (acc shl 8) or c.code })
        header.putShort(version.toShort())
        header.putShort(recordSize.toShort())
        header.putInt(0)
        header.putDouble(createdAt)
        out.write(header.array())
    }

    /** Fills one record with `fill` (which must write exactly `recordSize` bytes) and appends it. */
    fun append(fill: (ByteBuffer) -> Unit) {
        record.clear()
        fill(record)
        check(record.position() == recordSize) { "record wrote ${record.position()} of $recordSize bytes" }
        out.write(record.array())
        count++
    }

    fun flush() = out.flush()

    fun close() = out.close()

    companion object {
        const val HEADER_SIZE = 32
        const val MAGIC = 0x4453_424E // "DSBN"
    }
}
