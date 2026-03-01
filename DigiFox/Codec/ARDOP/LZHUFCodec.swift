/// LZHUF compression for the Winlink B2F protocol — Swift wrapper around C implementation.
///
/// The heavy lifting is done by lzhuf.c, a faithful C port of:
///   - Original algorithm: Haruhiko Okumura, LZHUF (ar002), 1988–1989 (public domain)
///   - Go reference: la5nta/wl2k-go/lzhuf (MIT License)
///   - Used by Pat (la5nta/pat), the open-source Winlink client
///
/// This Swift class is a thin wrapper providing Data-in / Data-out convenience.

import Foundation

final class LZHUFCodec {

    /// Compress data using LZHUF.
    /// Returns [4-byte LE filesize] + [compressed data].
    func compress(_ data: Data) -> Data {
        guard !data.isEmpty else {
            // Empty input: just the 4-byte zero size header
            return Data([0, 0, 0, 0])
        }
        let input = [UInt8](data)
        var outLen: Int = 0
        guard let ptr = input.withUnsafeBufferPointer({ buf in
            lzhuf_compress(buf.baseAddress, buf.count, &outLen)
        }) else {
            Log.d("LZHUF", "compress failed, returning empty")
            return Data([0, 0, 0, 0])
        }
        let result = Data(bytes: ptr, count: outLen)
        free(ptr)
        Log.d("LZHUF", "compressed \(data.count) → \(outLen) bytes")
        return result
    }

    /// Decompress LZHUF data.
    /// Input format: [4-byte LE filesize] + [compressed data].
    func decompress(_ data: Data) -> Data {
        guard data.count >= 4 else {
            Log.d("LZHUF", "decompress: input too short (\(data.count) bytes)")
            return Data()
        }
        let input = [UInt8](data)
        var outLen: Int = 0
        guard let ptr = input.withUnsafeBufferPointer({ buf in
            lzhuf_decompress(buf.baseAddress, buf.count, &outLen)
        }) else {
            Log.d("LZHUF", "decompress failed")
            return Data()
        }
        let result = Data(bytes: ptr, count: outLen)
        free(ptr)
        Log.d("LZHUF", "decompressed \(data.count) → \(outLen) bytes")
        return result
    }

    /// CRC-16 CCITT (Xmodem variant) as used by Winlink B2F.
    /// Includes 2 trailing zero bytes per wl2k-go convention.
    static func crc16(_ data: Data) -> UInt16 {
        let input = [UInt8](data)
        return input.withUnsafeBufferPointer { buf in
            lzhuf_crc16(buf.baseAddress, buf.count)
        }
    }
}
