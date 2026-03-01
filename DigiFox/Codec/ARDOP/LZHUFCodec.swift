/// LZHUF compression for the Winlink B2F protocol.
///
/// LZHUF (Lempel-Ziv Huffman) is the compression standard for Winlink messages.
/// This implementation follows the reference implementation exactly in
/// https://github.com/la5nta/wl2k-go/blob/master/lzhuf/lzhuf.go
///
/// Important parameters (must match wl2k-go):
///   N = 2048 (Sliding Window)
///   F = 60 (Lookahead)
///   Threshold = 2

import Foundation

final class LZHUFCodec {

    // MARK: - Constants (must match wl2k-go/lzhuf exactly)

    static let N = 2048                              // Ring buffer size
    static let F = 60                                // Lookahead buffer size
    static let threshold = 2                         // Encode as literal below this
    static let NIL = N                               // Tree nil marker
    static let numChar = 256 - threshold + F         // = 314
    static let T = numChar * 2 - 1                   // = 627 (tree size)
    static let R = T - 1                             // = 626 (root position)
    static let maxFreq: UInt = 0x8000                // Max frequency before reconst

    // MARK: - Huffman Tree

    private var freq = [UInt](repeating: 0, count: T + 1)
    private var prnt = [Int](repeating: 0, count: T + numChar)
    private var son = [Int](repeating: 0, count: T)

    // MARK: - LZ77 Tree

    private var dad = [Int](repeating: 0, count: N + 1)
    private var lson = [Int](repeating: 0, count: N + 1)
    private var rson = [Int](repeating: 0, count: N + 257)
    private var textBuf = [UInt8](repeating: 0x20, count: N + F - 1)
    private var matchLength = 0
    private var matchPosition = 0

    // MARK: - Bit I/O

    private var putBuf: UInt = 0
    private var putLen: UInt8 = 0
    private var getBuf: UInt = 0
    private var getLen: UInt8 = 0

    // MARK: - Stream I/O

    private var inputData = Data()
    private var inputPos = 0
    private var outputData = Data()

    // MARK: - Position Code Tables (from wl2k-go, verified against C reference)

    private static let pCode: [UInt8] = [
        0x00, 0x20, 0x30, 0x40, 0x50, 0x58, 0x60, 0x68,
        0x70, 0x78, 0x80, 0x88, 0x90, 0x94, 0x98, 0x9C,
        0xA0, 0xA4, 0xA8, 0xAC, 0xB0, 0xB4, 0xB8, 0xBC,
        0xC0, 0xC2, 0xC4, 0xC6, 0xC8, 0xCA, 0xCC, 0xCE,
        0xD0, 0xD2, 0xD4, 0xD6, 0xD8, 0xDA, 0xDC, 0xDE,
        0xE0, 0xE2, 0xE4, 0xE6, 0xE8, 0xEA, 0xEC, 0xEE,
        0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7,
        0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
    ]

    private static let pLen: [UInt8] = [
        0x03, 0x04, 0x04, 0x04, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x06, 0x06, 0x06, 0x06,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
        0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
    ]

    private static let dCode: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09,
        0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B,
        0x0C, 0x0C, 0x0C, 0x0C, 0x0D, 0x0D, 0x0D, 0x0D, 0x0E, 0x0E, 0x0E, 0x0E, 0x0F, 0x0F, 0x0F, 0x0F,
        0x10, 0x10, 0x10, 0x10, 0x11, 0x11, 0x11, 0x11, 0x12, 0x12, 0x12, 0x12, 0x13, 0x13, 0x13, 0x13,
        0x14, 0x14, 0x14, 0x14, 0x15, 0x15, 0x15, 0x15, 0x16, 0x16, 0x16, 0x16, 0x17, 0x17, 0x17, 0x17,
        0x18, 0x18, 0x19, 0x19, 0x1A, 0x1A, 0x1B, 0x1B, 0x1C, 0x1C, 0x1D, 0x1D, 0x1E, 0x1E, 0x1F, 0x1F,
        0x20, 0x20, 0x21, 0x21, 0x22, 0x22, 0x23, 0x23, 0x24, 0x24, 0x25, 0x25, 0x26, 0x26, 0x27, 0x27,
        0x28, 0x28, 0x29, 0x29, 0x2A, 0x2A, 0x2B, 0x2B, 0x2C, 0x2C, 0x2D, 0x2D, 0x2E, 0x2E, 0x2F, 0x2F,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
    ]

    private static let dLen: [UInt8] = [
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
        0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
        0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
    ]

    // MARK: - Public API

    /// Compresses data using LZHUF (compatible with wl2k-go/lzhuf).
    func compress(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0, 0, 0, 0]) }
        Log.d("LZHUF", "compress: \(data.count) bytes input")

        inputData = data
        inputPos = 0
        outputData = Data()
        putBuf = 0
        putLen = 0

        // 4-byte little-endian size header
        var size = UInt32(data.count)
        outputData.append(contentsOf: withUnsafeBytes(of: &size) { Array($0) })

        resetState()
        encode()

        Log.d("LZHUF", "compress: \(outputData.count) bytes output (ratio: \(String(format: "%.1f%%", Double(outputData.count) / Double(data.count) * 100)))")
        return outputData
    }

    /// Decompresses LZHUF data (compatible with wl2k-go/lzhuf).
    func decompress(_ data: Data) -> Data {
        guard data.count >= 4 else { return Data() }

        inputData = data
        inputPos = 4
        getBuf = 0
        getLen = 0

        let originalSize = Int(data[0]) | (Int(data[1]) << 8) | (Int(data[2]) << 16) | (Int(data[3]) << 24)
        guard originalSize > 0, originalSize < 10_000_000 else { return Data() }
        Log.d("LZHUF", "decompress: \(data.count) bytes input, original size: \(originalSize)")

        outputData = Data()
        outputData.reserveCapacity(originalSize)

        resetState()
        decode(originalSize: originalSize)

        Log.d("LZHUF", "decompress: \(outputData.count) bytes output")
        return outputData
    }

    // MARK: - Init / Reset

    private func resetState() {
        // Init Huffman tree (matches wl2k-go newLZHUFF)
        for i in 0..<Self.numChar {
            freq[i] = 1
            son[i] = i + Self.T
            prnt[i + Self.T] = i
        }

        var i = 0
        var j = Self.numChar
        while j <= Self.R {
            freq[j] = freq[i] + freq[i + 1]
            son[j] = i
            prnt[i] = j
            prnt[i + 1] = j
            i += 2
            j += 1
        }
        freq[Self.T] = 0xFFFF
        prnt[Self.R] = 0

        // Init LZ tree
        for i in (Self.N + 1)..<(Self.N + 257) {
            rson[i] = Self.NIL
        }
        for i in 0..<Self.N {
            dad[i] = Self.NIL
        }

        // Init text buffer with spaces
        textBuf = [UInt8](repeating: 0x20, count: Self.N + Self.F - 1)
    }

    // MARK: - Huffman Tree Operations

    private func reconst() {
        // Collect leaf nodes (matches wl2k-go reconst exactly)
        var j = 0
        for i in 0..<Self.T {
            if son[i] >= Self.T {
                freq[j] = (freq[i] + 1) / 2
                son[j] = son[i]
                j += 1
            }
        }

        // Build tree from leaves
        var i2 = 0
        j = Self.numChar
        while j < Self.T {
            let k2 = i2 + 1
            let f = freq[i2] + freq[k2]
            freq[j] = f

            var k = j
            while f < freq[k - 1] {
                k -= 1
            }

            let moveCount = j - k
            if moveCount > 0 {
                // Shift freq and son arrays right by 1 at position k
                for m in stride(from: k + moveCount, through: k + 1, by: -1) {
                    freq[m] = freq[m - 1]
                    son[m] = son[m - 1]
                }
            }
            freq[k] = f
            son[k] = i2

            i2 += 2
            j += 1
        }

        // Fix parent references
        for i in 0..<Self.T {
            let k = son[i]
            if k >= Self.T {
                prnt[k] = i
            } else {
                prnt[k] = i
                prnt[k + 1] = i
            }
        }
    }

    private func update(_ c: Int) {
        if freq[Self.R] == Self.maxFreq {
            reconst()
        }

        var c = prnt[c + Self.T]
        while true {
            freq[c] += 1

            // Check order with next node
            if freq[c] <= freq[c + 1] || c + 2 > freq.count {
                c = prnt[c]
                if c == 0 { break }
                continue
            }

            var l = c + 1
            let k = freq[c]
            while k > freq[l + 1] {
                l += 1
            }

            freq[c] = freq[l]
            freq[l] = k

            let i = son[c]
            prnt[i] = l
            if i < Self.T { prnt[i + 1] = l }

            let j2 = son[l]
            son[l] = i

            prnt[j2] = c
            if j2 < Self.T { prnt[j2 + 1] = c }
            son[c] = j2

            c = prnt[l]
            if c == 0 { break }
        }
    }

    // MARK: - LZ77 Tree

    private func insertNode(_ r: Int) {
        var cmp = 1
        var p = Self.N + 1 + Int(textBuf[r])
        rson[r] = Self.NIL
        lson[r] = Self.NIL
        matchLength = 0

        while true {
            if cmp >= 0 {
                if rson[p] != Self.NIL {
                    p = rson[p]
                } else {
                    rson[p] = r; dad[r] = p; return
                }
            } else {
                if lson[p] != Self.NIL {
                    p = lson[p]
                } else {
                    lson[p] = r; dad[r] = p; return
                }
            }

            var i = 1
            while i < Self.F {
                cmp = Int(textBuf[r + i]) - Int(textBuf[p + i])
                if cmp != 0 { break }
                i += 1
            }

            if i > Self.threshold {
                if i > matchLength {
                    // Key difference vs our old code: (r - p) & (N-1) - 1
                    matchPosition = ((r - p) & (Self.N - 1)) - 1
                    matchLength = i
                    if matchLength >= Self.F { break }
                }
                if i == matchLength {
                    let c = ((r - p) & (Self.N - 1)) - 1
                    if c < matchPosition {
                        matchPosition = c
                    }
                }
            }
        }

        dad[r] = dad[p]
        lson[r] = lson[p]
        rson[r] = rson[p]
        dad[lson[p]] = r
        dad[rson[p]] = r
        if rson[dad[p]] == p {
            rson[dad[p]] = r
        } else {
            lson[dad[p]] = r
        }
        dad[p] = Self.NIL
    }

    private func deleteNode(_ p: Int) {
        guard dad[p] != Self.NIL else { return }

        var q: Int
        if rson[p] == Self.NIL {
            q = lson[p]
        } else if lson[p] == Self.NIL {
            q = rson[p]
        } else {
            q = lson[p]
            if rson[q] != Self.NIL {
                repeat { q = rson[q] } while rson[q] != Self.NIL
                rson[dad[q]] = lson[q]
                dad[lson[q]] = dad[q]
                lson[q] = lson[p]
                dad[lson[p]] = q
            }
            rson[q] = rson[p]
            dad[rson[p]] = q
        }

        dad[q] = dad[p]
        if rson[dad[p]] == p {
            rson[dad[p]] = q
        } else {
            lson[dad[p]] = q
        }
        dad[p] = Self.NIL
    }

    // MARK: - Bit I/O

    private func readByte() -> Int {
        guard inputPos < inputData.count else { return -1 }
        let b = Int(inputData[inputPos])
        inputPos += 1
        return b
    }

    private func writeByte(_ b: UInt8) {
        outputData.append(b)
    }

    private func putcode(_ l: Int, _ c: UInt) {
        putBuf |= c >> putLen
        putLen += UInt8(l)
        if putLen >= 8 {
            writeByte(UInt8(truncatingIfNeeded: putBuf >> 8))
            putLen -= 8
            if putLen >= 8 {
                writeByte(UInt8(truncatingIfNeeded: putBuf))
                putLen -= 8
                putBuf = c << UInt(l - Int(putLen))
            } else {
                putBuf <<= 8
            }
        }
    }

    private func getBit() -> Int {
        while getLen <= 8 {
            let i = readByte()
            getBuf |= UInt(i < 0 ? 0 : i) << (8 - getLen)
            getLen += 8
        }
        let bit = Int((getBuf >> 15) & 1)
        getBuf <<= 1
        getLen -= 1
        return bit
    }

    private func getByte() -> Int {
        while getLen <= 8 {
            let i = readByte()
            getBuf |= UInt(i < 0 ? 0 : i) << (8 - getLen)
            getLen += 8
        }
        let byte = Int(getBuf >> 8) & 0xFF
        getBuf <<= 8
        getLen -= 8
        return byte
    }

    // MARK: - Huffman Encode/Decode

    private func encodeChar(_ c: Int) {
        var code: UInt = 0
        var len: UInt8 = 0
        var k = prnt[c + Self.T]

        repeat {
            code >>= 1
            if k & 1 != 0 { code |= 0x8000 }
            len += 1
            k = prnt[k]
        } while k != Self.R

        putcode(Int(len), code)
        update(c)
    }

    private func encodePosition(_ c: Int) {
        let i = c >> 6
        putcode(Int(Self.pLen[i]), UInt(Self.pCode[i]) << 8)
        putcode(6, UInt(c & 0x3F) << 10)
    }

    private func decodeChar() -> Int {
        var c = son[Self.R]
        while c < Self.T {
            c += getBit()
            c = son[c]
        }
        c -= Self.T
        update(c)
        return c
    }

    private func decodePosition() -> Int {
        var i = getByte()
        let c = Int(Self.dCode[i]) << 6
        var j = Int(Self.dLen[i]) - 2
        while j > 0 {
            i = (i << 1) | getBit()
            j -= 1
        }
        return c | (i & 0x3F)
    }

    // MARK: - Encode

    private func encode() {
        let n = Self.N
        let f = Self.F

        var r = n - f
        var s = 0
        var len = 0

        // Fill lookahead buffer
        while len < f {
            let c = readByte()
            guard c >= 0 else { break }
            textBuf[r + len] = UInt8(c)
            len += 1
        }
        guard len > 0 else { return }

        for i in 1...f { insertNode(r - i) }
        insertNode(r)

        repeat {
            if matchLength > len { matchLength = len }

            if matchLength <= Self.threshold {
                matchLength = 1
                encodeChar(Int(textBuf[r]))
            } else {
                encodeChar(256 - Self.threshold + matchLength)
                encodePosition(matchPosition)
            }

            let lastMatchLength = matchLength
            var i = 0
            while i < lastMatchLength {
                let c = readByte()
                guard c >= 0 else { break }
                deleteNode(s)
                textBuf[s] = UInt8(c)
                if s < f - 1 { textBuf[s + n] = UInt8(c) }
                s = (s + 1) & (n - 1)
                r = (r + 1) & (n - 1)
                insertNode(r)
                i += 1
            }

            while i < lastMatchLength {
                i += 1
                deleteNode(s)
                s = (s + 1) & (n - 1)
                r = (r + 1) & (n - 1)
                len -= 1
                if len > 0 { insertNode(r) }
            }
        } while len > 0

        if putLen > 0 {
            writeByte(UInt8(truncatingIfNeeded: putBuf >> 8))
        }
    }

    // MARK: - Decode

    private func decode(originalSize: Int) {
        let n = Self.N
        let f = Self.F

        textBuf = [UInt8](repeating: 0x20, count: n + f - 1)
        var r = n - f
        var count = 0

        while count < originalSize {
            let c = decodeChar()

            if c < 256 {
                let byte = UInt8(c)
                outputData.append(byte)
                textBuf[r] = byte
                r = (r + 1) & (n - 1)
                count += 1
            } else {
                let i = (r - decodePosition() - 1) & (n - 1)
                let j = c - 255 + Self.threshold
                for k in 0..<j {
                    let byte = textBuf[(i + k) & (n - 1)]
                    outputData.append(byte)
                    textBuf[r] = byte
                    r = (r + 1) & (n - 1)
                    count += 1
                    if count >= originalSize { break }
                }
            }
        }
    }
}
