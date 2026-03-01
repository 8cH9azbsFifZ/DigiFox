/// LZHUF-Kompression für das Winlink B2F-Protokoll.
///
/// LZHUF (Lempel-Ziv Huffman) ist der Kompressionsstandard für Winlink-Nachrichten.
/// Basiert auf dem LZHUF-Algorithmus von Haruyasu Yoshizaki (1988).
///
/// Referenz: https://github.com/la5nta/wl2k-go (Go-Implementierung in lzhuf/)
///
/// Der Algorithmus kombiniert LZ77 Sliding-Window-Kompression mit adaptiver
/// Huffman-Kodierung für optimale Kompressionsraten bei Textnachrichten.

import Foundation

final class LZHUFCodec {

    // MARK: - LZHUF Constants

    /// Sliding window size (ring buffer)
    static let windowSize = 4096       // N
    /// Lookahead buffer size
    static let lookaheadSize = 60      // F
    /// Match threshold — encode as literal if match length < this
    static let matchThreshold = 2     // THRESHOLD

    /// Huffman tree size constants
    static let charTableSize = 256 + lookaheadSize - matchThreshold + 1  // = 314
    /// Total tree nodes (charTableSize * 2 - 1)
    static let treeSize = charTableSize * 2 - 1  // = 627
    /// Root of Huffman tree
    static let rootNode = treeSize - 1           // = 626

    /// Position tree constants (for encoding match positions)
    static let positionBits = 12  // log2(windowSize)

    // MARK: - Huffman Tree State

    private var freq = [Int](repeating: 0, count: treeSize + 1)
    private var parent = [Int](repeating: 0, count: treeSize + 1)
    private var son = [Int](repeating: 0, count: treeSize + 1)

    // MARK: - Ring Buffer

    private var textBuf = [UInt8](repeating: 0x20, count: LZHUFCodec.windowSize + LZHUFCodec.lookaheadSize - 1)

    // MARK: - Bit I/O State

    private var putBuf: UInt32 = 0
    private var putLen: Int = 0
    private var getBuf: UInt32 = 0
    private var getLen: Int = 0

    // MARK: - Output buffer

    private var outputData = Data()
    private var inputData = Data()
    private var inputPos = 0

    // MARK: - Public API

    /// Komprimiert Daten mit LZHUF.
    /// - Parameter data: Unkomprimierte Eingabedaten
    /// - Returns: LZHUF-komprimierte Daten (mit 4-Byte Längenpräfix, Little-Endian)
    func compress(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0, 0, 0, 0]) }

        inputData = data
        inputPos = 0
        outputData = Data()
        putBuf = 0
        putLen = 0

        // Write original size as 4-byte little-endian header
        var size = UInt32(data.count)
        outputData.append(contentsOf: withUnsafeBytes(of: &size) { Array($0) })

        initTree()
        startHuff()
        encode()

        return outputData
    }

    /// Dekomprimiert LZHUF-Daten.
    /// - Parameter data: LZHUF-komprimierte Daten (mit 4-Byte Längenpräfix)
    /// - Returns: Dekomprimierte Originaldaten
    func decompress(_ data: Data) -> Data {
        guard data.count >= 4 else { return Data() }

        inputData = data
        inputPos = 4 // skip size header
        getBuf = 0
        getLen = 0

        let originalSize = Int(data[0]) | (Int(data[1]) << 8) | (Int(data[2]) << 16) | (Int(data[3]) << 24)
        guard originalSize > 0 else { return Data() }

        outputData = Data()
        outputData.reserveCapacity(originalSize)

        startHuff()
        decode(originalSize: originalSize)

        return outputData
    }

    // MARK: - Huffman Tree

    private func startHuff() {
        for i in 0..<LZHUFCodec.charTableSize {
            freq[i] = 1
            son[i] = i + LZHUFCodec.treeSize
            parent[i + LZHUFCodec.treeSize] = i
        }

        var i = 0
        var j = LZHUFCodec.charTableSize
        while j <= LZHUFCodec.rootNode {
            freq[j] = freq[i] + freq[i + 1]
            son[j] = i
            parent[i] = j
            parent[i + 1] = j
            i += 2
            j += 1
        }

        freq[LZHUFCodec.treeSize] = 0xFFFF
        parent[LZHUFCodec.rootNode] = 0
    }

    /// Reconstruct the Huffman tree when frequencies get too large
    private func reconst() {
        // Collect leaf nodes
        var j = 0
        for i in 0..<LZHUFCodec.treeSize {
            if son[i] >= LZHUFCodec.treeSize {
                freq[j] = (freq[i] + 1) / 2
                son[j] = son[i]
                j += 1
            }
        }

        // Build tree from leaves
        var i = 0
        j = LZHUFCodec.charTableSize
        while j < LZHUFCodec.treeSize {
            var k = i + 1
            let f = freq[i] + freq[k]
            freq[j] = f
            k = j - 1
            while f < freq[k] { k -= 1 }
            k += 1

            let copyLen = (j - k) * MemoryLayout<Int>.size
            if copyLen > 0 {
                freq.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress!.advanced(by: k + 1).assign(from: buf.baseAddress!.advanced(by: k), count: j - k)
                }
                son.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress!.advanced(by: k + 1).assign(from: buf.baseAddress!.advanced(by: k), count: j - k)
                }
            }

            freq[k] = f
            son[k] = i
            i += 2
            j += 1
        }

        // Fix parent references
        for i in 0..<LZHUFCodec.treeSize {
            let k = son[i]
            if k >= LZHUFCodec.treeSize {
                parent[k] = i
            } else {
                parent[k] = i
                parent[k + 1] = i
            }
        }
    }

    /// Update the Huffman tree after encoding/decoding a character
    private func update(_ c: Int) {
        var c = c
        if freq[LZHUFCodec.rootNode] == 0x8000 {
            reconst()
        }

        c = parent[c + LZHUFCodec.treeSize]
        repeat {
            freq[c] += 1
            let k = freq[c]

            // Swap nodes if frequency order is violated
            var l = c + 1
            if k > freq[l] {
                while k > freq[l + 1] { l += 1 }
                freq[c] = freq[l]
                freq[l] = k

                let sonC = son[c]
                let sonL = son[l]
                son[l] = sonC
                parent[sonC] = l
                if sonC < LZHUFCodec.treeSize {
                    parent[sonC + 1] = l
                }
                son[c] = sonL
                parent[sonL] = c
                if sonL < LZHUFCodec.treeSize {
                    parent[sonL + 1] = c
                }
                c = l
            }
            c = parent[c]
        } while c != 0
    }

    // MARK: - Bit I/O

    private func writeByte(_ b: UInt8) {
        outputData.append(b)
    }

    private func readByte() -> Int {
        guard inputPos < inputData.count else { return -1 }
        let b = Int(inputData[inputPos])
        inputPos += 1
        return b
    }

    private func putCode(_ length: Int, _ code: UInt32) {
        putBuf |= code >> putLen
        putLen += length
        if putLen >= 8 {
            writeByte(UInt8(putBuf >> 8))
            putLen -= 8
            if putLen >= 8 {
                writeByte(UInt8(putBuf & 0xFF))
                putLen -= 8
                putBuf = code << (length - putLen)
            } else {
                putBuf <<= 8
            }
        }
    }

    private func getBit() -> Int {
        while getLen <= 8 {
            let b = readByte()
            let i = b < 0 ? 0 : b
            getBuf |= UInt32(i) << (8 - getLen)
            getLen += 8
        }
        let bit = Int((getBuf >> 15) & 1)
        getBuf <<= 1
        getLen -= 1
        return bit
    }

    private func getByte() -> Int {
        while getLen <= 8 {
            let b = readByte()
            let i = b < 0 ? 0 : b
            getBuf |= UInt32(i) << (8 - getLen)
            getLen += 8
        }
        let byte = Int(getBuf >> 8)
        getBuf <<= 8
        getLen -= 8
        return byte
    }

    // MARK: - Huffman Encode/Decode

    private func encodeChar(_ c: Int) {
        var code: UInt32 = 0
        var len = 0
        var k = parent[c + LZHUFCodec.treeSize]

        // Traverse from leaf to root to build code
        repeat {
            code >>= 1
            if k & 1 != 0 {
                code |= 0x8000_0000
            }
            len += 1
            k = parent[k]
        } while k != LZHUFCodec.rootNode

        // Reverse and output
        putCode(len, code >> (32 - len))
        update(c)
    }

    private func encodePosition(_ c: Int) {
        // Encode upper 6 bits via table
        let i = c >> 6
        putCode(Int(pCodeLen[i]), UInt32(pCode[i]) << 8)
        // Encode lower 6 bits directly
        putCode(6, UInt32(c & 0x3F) << 10)
    }

    private func decodeChar() -> Int {
        var c = son[LZHUFCodec.rootNode]

        // Traverse tree from root to leaf
        while c < LZHUFCodec.treeSize {
            c += getBit()
            c = son[c]
        }
        c -= LZHUFCodec.treeSize
        update(c)
        return c
    }

    private func decodePosition() -> Int {
        // Decode upper 6 bits via table
        var i = getByte()
        let c = Int(dCode[i]) << 6
        let j = Int(dLen[i])

        // Read remaining bits
        var k = j - 2
        while k > 0 {
            i = (i << 1) | getBit()
            k -= 1
        }

        return c | (i & 0x3F)
    }

    // MARK: - LZ77 Matching (Binary Search Tree)

    private var lson = [Int](repeating: 0, count: LZHUFCodec.windowSize + 1)
    private var rson = [Int](repeating: 0, count: LZHUFCodec.windowSize + 257)
    private var dad = [Int](repeating: 0, count: LZHUFCodec.windowSize + 1)

    private var matchPosition = 0
    private var matchLength = 0

    private func initTree() {
        let n = LZHUFCodec.windowSize
        for i in (n + 1)..<(n + 257) {
            rson[i] = n // NIL
        }
        for i in 0..<n {
            dad[i] = n  // NIL
        }
    }

    private func insertNode(_ r: Int) {
        let n = LZHUFCodec.windowSize
        let f = LZHUFCodec.lookaheadSize
        var cmp = 1
        var p = n + 1 + Int(textBuf[r])
        rson[r] = n
        lson[r] = n
        matchLength = 0

        while true {
            if cmp >= 0 {
                if rson[p] != n {
                    p = rson[p]
                } else {
                    rson[p] = r
                    dad[r] = p
                    return
                }
            } else {
                if lson[p] != n {
                    p = lson[p]
                } else {
                    lson[p] = r
                    dad[r] = p
                    return
                }
            }

            var i = 1
            cmp = 0
            while i < f {
                cmp = Int(textBuf[r + i]) - Int(textBuf[p + i])
                if cmp != 0 { break }
                i += 1
            }

            if i > matchLength {
                matchPosition = p
                matchLength = i
                if matchLength >= f { break }
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
        dad[p] = n // remove p (NIL)
    }

    private func deleteNode(_ p: Int) {
        let n = LZHUFCodec.windowSize
        guard dad[p] != n else { return } // not in tree

        var q: Int
        if rson[p] == n {
            q = lson[p]
        } else if lson[p] == n {
            q = rson[p]
        } else {
            q = lson[p]
            if rson[q] != n {
                repeat { q = rson[q] } while rson[q] != n
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
        dad[p] = n
    }

    // MARK: - Encode / Decode

    private func encode() {
        let n = LZHUFCodec.windowSize
        let f = LZHUFCodec.lookaheadSize

        // Initialize buffer with spaces
        textBuf = [UInt8](repeating: 0x20, count: n + f - 1)
        initTree()

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

        // Insert initial strings into tree
        for i in 1...f {
            insertNode(r - i)
        }
        insertNode(r)

        repeat {
            if matchLength > len {
                matchLength = len
            }

            if matchLength <= LZHUFCodec.matchThreshold {
                // Encode single character
                matchLength = 1
                encodeChar(Int(textBuf[r]))
            } else {
                // Encode match (length, position)
                encodeChar(256 - LZHUFCodec.matchThreshold + matchLength)
                encodePosition(matchPosition)
            }

            let lastMatchLength = matchLength
            var i = 0
            while i < lastMatchLength {
                let c = readByte()
                guard c >= 0 else { break }
                deleteNode(s)
                textBuf[s] = UInt8(c)
                if s < f - 1 {
                    textBuf[s + n] = UInt8(c) // guard for lookahead wrap
                }
                s = (s + 1) & (n - 1)
                r = (r + 1) & (n - 1)
                insertNode(r)
                i += 1
            }

            while i < lastMatchLength {
                deleteNode(s)
                s = (s + 1) & (n - 1)
                r = (r + 1) & (n - 1)
                len -= 1
                if len > 0 { insertNode(r) }
                i += 1
            }
        } while len > 0

        // Flush remaining bits
        if putLen > 0 {
            writeByte(UInt8(putBuf >> 8))
        }
    }

    private func decode(originalSize: Int) {
        let n = LZHUFCodec.windowSize
        let f = LZHUFCodec.lookaheadSize

        textBuf = [UInt8](repeating: 0x20, count: n + f - 1)

        var r = n - f
        var count = 0

        while count < originalSize {
            let c = decodeChar()

            if c < 256 {
                // Literal byte
                let byte = UInt8(c)
                outputData.append(byte)
                textBuf[r] = byte
                r = (r + 1) & (n - 1)
                count += 1
            } else {
                // Match: decode position + length
                let i = (r - decodePosition() - 1) & (n - 1)
                let j = c - 255 + LZHUFCodec.matchThreshold
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

    // MARK: - Position Encoding/Decoding Tables

    /// Position code table (upper 6 bits encoded as variable-length prefix)
    private let pCode: [UInt8] = [
        0x00, 0x20, 0x30, 0x40, 0x50, 0x58, 0x60, 0x68,
        0x70, 0x74, 0x78, 0x7C, 0x80, 0x82, 0x84, 0x86,
        0x88, 0x8A, 0x8C, 0x8E, 0x90, 0x91, 0x92, 0x93,
        0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B,
        0x9C, 0x9D, 0x9E, 0x9F, 0xA0, 0xA1, 0xA2, 0xA3,
        0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB,
        0xAC, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3,
        0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB,
    ]

    /// Position code length table (number of bits for each prefix)
    private let pCodeLen: [UInt8] = [
        3, 4, 4, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 6, 6, 6, 6,
        6, 6, 6, 6, 6, 6, 6, 6,
        7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7,
        8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8,
    ]

    /// Position decode table (inverse of pCode)
    private let dCode: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            if i < 0x20 { table[i] = 0 }
            else if i < 0x30 { table[i] = 1 }
            else if i < 0x40 { table[i] = 2 }
            else if i < 0x50 { table[i] = 3 }
            else if i < 0x58 { table[i] = 4 }
            else if i < 0x60 { table[i] = 5 }
            else if i < 0x68 { table[i] = 6 }
            else if i < 0x70 { table[i] = 7 }
            else if i < 0x74 { table[i] = 8 }
            else if i < 0x78 { table[i] = 9 }
            else if i < 0x7C { table[i] = 10 }
            else if i < 0x80 { table[i] = 11 }
            else if i < 0x82 { table[i] = 12 }
            else if i < 0x84 { table[i] = 13 }
            else if i < 0x86 { table[i] = 14 }
            else if i < 0x88 { table[i] = 15 }
            else if i < 0x8A { table[i] = 16 }
            else if i < 0x8C { table[i] = 17 }
            else if i < 0x8E { table[i] = 18 }
            else if i < 0x90 { table[i] = 19 }
            else if i < 0x91 { table[i] = 20 }
            else if i < 0x92 { table[i] = 21 }
            else if i < 0x93 { table[i] = 22 }
            else if i < 0x94 { table[i] = 23 }
            else if i < 0x95 { table[i] = 24 }
            else if i < 0x96 { table[i] = 25 }
            else if i < 0x97 { table[i] = 26 }
            else if i < 0x98 { table[i] = 27 }
            else if i < 0x99 { table[i] = 28 }
            else if i < 0x9A { table[i] = 29 }
            else if i < 0x9B { table[i] = 30 }
            else if i < 0x9C { table[i] = 31 }
            else if i < 0x9D { table[i] = 32 }
            else if i < 0x9E { table[i] = 33 }
            else if i < 0x9F { table[i] = 34 }
            else if i < 0xA0 { table[i] = 35 }
            else { table[i] = UInt8((i - 0xA0) / 2 + 36) }
        }
        return table
    }()

    /// Position decode length table
    private let dLen: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            if i < 0x20 { table[i] = 3 }
            else if i < 0x50 { table[i] = 4 }
            else if i < 0x70 { table[i] = 4 }
            else if i < 0x80 { table[i] = 5 }
            else if i < 0x90 { table[i] = 5 }
            else if i < 0x9C { table[i] = 6 }
            else if i < 0xA0 { table[i] = 6 }
            else if i < 0xC0 { table[i] = 7 }
            else { table[i] = 8 }
        }
        return table
    }()
}
