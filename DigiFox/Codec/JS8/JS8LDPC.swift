import Foundation

/// LDPC(174,91) codec for FT8/JS8 forward error correction.
/// Uses a quasi-cyclic construction with belief propagation decoding.
class LDPCCodec {
    static let N = 174  // codeword length
    static let K = 91   // message bits
    static let M = 83   // parity checks

    private let checkToVar: [[Int]]
    private let varToCheck: [[Int]]
    private let chkEdgeIdx: [[Int: Int]]
    private let varEdgeIdx: [[Int: Int]]

    init() {
        let c2v = LDPCCodec.buildParityCheckMatrix()
        self.checkToVar = c2v

        var v2c = [[Int]](repeating: [], count: LDPCCodec.N)
        for (ci, vars) in c2v.enumerated() {
            for vi in vars { v2c[vi].append(ci) }
        }
        self.varToCheck = v2c

        // Pre-build edge index lookups for fast BP
        var vIdx = [[Int: Int]]()
        for vi in 0..<LDPCCodec.N {
            var lookup = [Int: Int]()
            for (idx, ci) in v2c[vi].enumerated() { lookup[ci] = idx }
            vIdx.append(lookup)
        }
        self.varEdgeIdx = vIdx

        var cIdx = [[Int: Int]]()
        for ci in 0..<LDPCCodec.M {
            var lookup = [Int: Int]()
            for (idx, vi) in c2v[ci].enumerated() { lookup[vi] = idx }
            cIdx.append(lookup)
        }
        self.chkEdgeIdx = cIdx
    }

    // MARK: - Encoding

    /// Systematic encoding: message[0..<91] → codeword[0..<174]
    func encode(_ message: [UInt8]) -> [UInt8] {
        guard message.count == LDPCCodec.K else { return [] }
        var codeword = [UInt8](repeating: 0, count: LDPCCodec.N)
        for i in 0..<LDPCCodec.K { codeword[i] = message[i] }
        // Parity: for each check, XOR the connected message bits
        for ci in 0..<LDPCCodec.M {
            var p: UInt8 = 0
            for vi in checkToVar[ci] where vi < LDPCCodec.K {
                p ^= message[vi]
            }
            codeword[LDPCCodec.K + ci] = p
        }
        return codeword
    }

    // MARK: - Decoding (Min-Sum Belief Propagation)

    /// Decode from log-likelihood ratios. Positive LLR = more likely 0.
    func decode(_ llr: [Double], maxIter: Int = 50) -> [UInt8]? {
        guard llr.count == LDPCCodec.N else { return nil }

        // Variable-to-check messages
        var varMsg = (0..<LDPCCodec.N).map { vi in
            [Double](repeating: llr[vi], count: varToCheck[vi].count)
        }
        // Check-to-variable messages
        var chkMsg = (0..<LDPCCodec.M).map { ci in
            [Double](repeating: 0.0, count: checkToVar[ci].count)
        }

        for _ in 0..<maxIter {
            // Check node update (min-sum with 0.8 scaling)
            for ci in 0..<LDPCCodec.M {
                let edges = checkToVar[ci]
                let deg = edges.count
                var incoming = [Double](repeating: 0, count: deg)
                for (j, vi) in edges.enumerated() {
                    incoming[j] = varMsg[vi][varEdgeIdx[vi][ci] ?? 0]
                }
                for j in 0..<deg {
                    var minAbs = Double.infinity
                    var sign = 1.0
                    for k in 0..<deg where k != j {
                        if incoming[k] < 0 { sign = -sign }
                        let a = abs(incoming[k])
                        if a < minAbs { minAbs = a }
                    }
                    chkMsg[ci][j] = sign * minAbs * 0.8
                }
            }

            // Variable node update
            for vi in 0..<LDPCCodec.N {
                let edges = varToCheck[vi]
                var totalExtrinsic = llr[vi]
                for (_, ci) in edges.enumerated() {
                    totalExtrinsic += chkMsg[ci][chkEdgeIdx[ci][vi] ?? 0]
                }
                for (j, ci) in edges.enumerated() {
                    varMsg[vi][j] = totalExtrinsic - chkMsg[ci][chkEdgeIdx[ci][vi] ?? 0]
                }
            }

            // Hard decision + syndrome check
            var bits = [UInt8](repeating: 0, count: LDPCCodec.N)
            for vi in 0..<LDPCCodec.N {
                var total = llr[vi]
                for ci in varToCheck[vi] {
                    total += chkMsg[ci][chkEdgeIdx[ci][vi] ?? 0]
                }
                bits[vi] = total < 0 ? 1 : 0
            }

            var valid = true
            for ci in 0..<LDPCCodec.M {
                var s: UInt8 = 0
                for vi in checkToVar[ci] { s ^= bits[vi] }
                if s != 0 { valid = false; break }
            }
            if valid { return Array(bits.prefix(LDPCCodec.K)) }
        }
        return nil
    }

    // MARK: - Parity Check Matrix Construction

    /// Build systematic LDPC parity check matrix H = [A | I_83].
    /// Quasi-cyclic construction with column weight 3 for message bits.
    static func buildParityCheckMatrix() -> [[Int]] {
        var colSets = Array(repeating: Set<Int>(), count: K)

        for col in 0..<K {
            var rows = Set<Int>()
            rows.insert(col % M)
            var r1 = (col &* 7 &+ 13) % M
            while rows.contains(r1) { r1 = (r1 + 1) % M }
            rows.insert(r1)
            var r2 = (col &* 11 &+ 37) % M
            while rows.contains(r2) { r2 = (r2 + 1) % M }
            rows.insert(r2)
            colSets[col] = rows
        }

        var matrix = [[Int]]()
        for row in 0..<M {
            var indices = [Int]()
            for col in 0..<K {
                if colSets[col].contains(row) { indices.append(col) }
            }
            indices.append(K + row) // identity part
            matrix.append(indices.sorted())
        }
        return matrix
    }
}
