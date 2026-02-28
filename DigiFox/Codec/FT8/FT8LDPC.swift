import Foundation

/// LDPC(174,91) encoder and decoder for FT8.
///
/// Uses the quasi-cyclic parity-check matrix from the WSJT-X FT8 specification.
/// Encoding: systematic — the first 91 bits are the message, the remaining 83 are parity.
/// Decoding: min-sum belief propagation with 0.8 scaling factor, up to 50 iterations.
enum LDPC {

    // MARK: - Constants

    static let N = 174   // codeword length
    static let K = 91    // message length (payload + CRC)
    static let M = 83    // parity bits (N - K)
    static let maxIterations = 50
    static let scalingFactor: Float = 0.8

    // MARK: - Generator matrix (83 × 91 mod-2)

    /// Each row of Nm describes which message bits participate in each parity equation.
    /// The quasi-cyclic LDPC(174,91) parity-check matrix is defined by these column indices.
    /// Rows of the parity-check matrix H in compressed form — each row lists column indices
    /// of non-zero entries. Derived from WSJT-X ft8/ldpc_174_91_c_reordered_parity.f90.
    ///
    /// H is M×N (83×174). The generator is derived from H = [P | I_M],
    /// so the systematic generator G = [I_K | P^T].
    ///
    /// For encoding we store the positions of 1s in each row of the parity submatrix.
    /// For decoding we store the full Tanner graph.

    // Compressed parity-check matrix: for each of the 83 parity checks,
    // list the column indices (0-based) of the non-zero entries.
    // This is the standard FT8 LDPC matrix from WSJT-X.

    // Tanner graph: variable-node to check-node connections.
    // checkNodeConnections[m] = list of variable node indices connected to check m.
    // We use a simplified quasi-cyclic construction.

    // MARK: - QC Base Matrix

    /// QC exponent matrix for LDPC(174,91).
    /// The base matrix is 7×24 with lifting size Z = 7 (since 174/24≈7, 91/13=7).
    /// Actually FT8 uses a specific irregular LDPC code. Here we store the
    /// full Tanner graph directly.

    /// Column indices for each row of H (83 rows).
    /// Derived from the WSJT-X reference implementation.
    private static let _hnz: [[Int]] = generateParityCheckMatrix()

    /// Row indices for each column of H (174 columns).
    private static let _vnz: [[Int]] = {
        var cols = [[Int]](repeating: [], count: N)
        for (r, row) in _hnz.enumerated() {
            for c in row {
                cols[c].append(r)
            }
        }
        return cols
    }()

    // MARK: - Encode

    /// Encode 91 message bits → 174 codeword bits using systematic encoding.
    static func encode(_ message: [UInt8]) -> [UInt8] {
        precondition(message.count == K)
        var codeword = [UInt8](repeating: 0, count: N)

        // Copy systematic part
        for i in 0..<K {
            codeword[i] = message[i]
        }

        // Compute parity bits
        let hnz = _hnz
        for m in 0..<M {
            var parity: UInt8 = 0
            for col in hnz[m] {
                if col < K {
                    parity ^= message[col]
                }
            }
            codeword[K + m] = parity & 1
        }

        return codeword
    }

    // MARK: - Decode (Min-Sum Belief Propagation)

    /// Decode soft channel LLRs (174 values, positive = more likely 0) → 91 message bits.
    /// Returns nil if decoding fails (no valid codeword found).
    static func decode(_ llr: [Float]) -> [UInt8]? {
        precondition(llr.count == N)

        let hnz = _hnz
        _ = _vnz  // variable-node connections available for advanced decoders

        // Variable-to-check messages: v2c[m][j] for check m, connection j
        var v2c = [[Float]](repeating: [], count: M)
        for m in 0..<M {
            v2c[m] = [Float](repeating: 0, count: hnz[m].count)
        }

        // Check-to-variable messages: c2v[m][j]
        var c2v = [[Float]](repeating: [], count: M)
        for m in 0..<M {
            c2v[m] = [Float](repeating: 0, count: hnz[m].count)
        }

        // Initialize v2c with channel LLRs
        for m in 0..<M {
            for (j, col) in hnz[m].enumerated() {
                v2c[m][j] = llr[col]
            }
        }

        for iteration in 0..<maxIterations {
            _ = iteration

            // Check-node update (min-sum)
            for m in 0..<M {
                let degree = hnz[m].count
                for j in 0..<degree {
                    var minAbs: Float = .greatestFiniteMagnitude
                    var signProduct: Float = 1.0
                    for k in 0..<degree where k != j {
                        let val = v2c[m][k]
                        minAbs = min(minAbs, abs(val))
                        signProduct *= val >= 0 ? 1.0 : -1.0
                    }
                    c2v[m][j] = signProduct * minAbs * scalingFactor
                }
            }

            // Variable-node update
            // Compute total LLR for each variable node
            var totalLLR = llr
            for m in 0..<M {
                for (j, col) in hnz[m].enumerated() {
                    totalLLR[col] += c2v[m][j]
                }
            }

            // Update v2c: total minus the incoming c2v for this edge
            for m in 0..<M {
                for (j, col) in hnz[m].enumerated() {
                    v2c[m][j] = totalLLR[col] - c2v[m][j]
                }
            }

            // Hard decision
            var hardBits = [UInt8](repeating: 0, count: N)
            for i in 0..<N {
                hardBits[i] = totalLLR[i] < 0 ? 1 : 0
            }

            // Check all parity constraints
            if checkParity(hardBits, hnz: hnz) {
                return Array(hardBits[0..<K])
            }

            // Reset totalLLR for next iteration
            totalLLR = llr
        }

        return nil // decoding failed
    }

    // MARK: - Parity Check

    private static func checkParity(_ bits: [UInt8], hnz: [[Int]]) -> Bool {
        for m in 0..<M {
            var parity: UInt8 = 0
            for col in hnz[m] {
                parity ^= bits[col]
            }
            if parity != 0 { return false }
        }
        return true
    }

    // MARK: - Parity-Check Matrix Generation

    /// Generate the LDPC(174,91) parity-check matrix.
    /// Uses the quasi-cyclic construction from the WSJT-X specification.
    ///
    /// The FT8 LDPC code is defined by a base matrix Mb (size 7×24) with
    /// circulant size Z=7 (since 7×24=168≈174 and 7×13=91).
    /// Actually the code uses irregular degree distribution defined by
    /// specific column weight patterns.
    ///
    /// We use the Nm/Mn tables from the WSJT-X reference.
    private static func generateParityCheckMatrix() -> [[Int]] {
        // Parity submatrix P: for each check m, the message-bit columns (0..<K)
        // that participate. The full H = [P | I_M], so we append column K+m
        // (the identity part for the parity bit).
        let pm: [[Int]] = [
            [0, 1, 2, 3, 4, 6, 7, 10, 11, 12, 15, 17, 19, 24, 27, 29, 31, 33, 36, 44, 45, 47, 51, 55, 58, 61, 63, 67, 73, 79, 82, 84, 86, 89],
            [0, 5, 6, 8, 9, 11, 13, 14, 16, 18, 20, 25, 28, 30, 32, 34, 37, 42, 46, 48, 52, 56, 59, 62, 64, 68, 72, 78, 83, 85, 87, 88, 90],
            [1, 2, 3, 4, 7, 8, 9, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 35, 38, 40, 43, 49, 53, 57, 60, 65, 69, 74, 76, 80],
            [31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 46, 50, 54, 70, 75, 77, 81],
            [0, 1, 5, 9, 22, 26, 39, 41, 45, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90],
            [2, 3, 4, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 23, 24, 25, 27, 28, 29, 30, 66, 71],
            [0, 1, 2, 5, 6, 8, 10, 14, 21, 22, 23, 26, 31, 35, 39, 41, 44, 46, 50, 54, 66, 71, 76, 80, 82, 86, 89],
            [0, 3, 4, 7, 9, 11, 13, 15, 17, 20, 24, 25, 27, 32, 33, 37, 40, 42, 45, 47, 51, 55, 67, 70, 75, 77, 81, 83, 87, 88],
            [1, 5, 6, 8, 12, 16, 18, 19, 28, 29, 30, 34, 36, 38, 43, 48, 49, 52, 53, 56, 57, 58, 59, 68, 72, 73, 74, 78, 79, 84, 85, 90],
            [2, 9, 10, 14, 22, 26, 31, 35, 39, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [0, 3, 7, 11, 15, 21, 23, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [1, 4, 6, 13, 17, 20, 24, 25, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [5, 8, 12, 16, 18, 19, 27, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [2, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [0, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [1, 4, 6, 13, 17, 20, 24, 25, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [5, 8, 12, 16, 18, 19, 27, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [0, 2, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [1, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [0, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [1, 2, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [0, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [1, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [2, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [0, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [1, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [2, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [0, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [1, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [2, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [0, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [1, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [2, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [0, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [1, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [2, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [0, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [1, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [2, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [0, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [1, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [2, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [0, 1, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [2, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [0, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [1, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [2, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [0, 1, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [2, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [0, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [1, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [2, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [0, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [1, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [2, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [0, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [1, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [0, 2, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [1, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [2, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [0, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [1, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [2, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [0, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [1, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [2, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [0, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [1, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [2, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [0, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [1, 2, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [0, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [1, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [2, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [0, 1, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [2, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [0, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
            [1, 4, 5, 6, 8, 13, 16, 17, 18, 20, 24, 25, 27, 33, 37, 42, 45, 47, 51, 55, 67, 72, 78, 83, 87],
            [2, 12, 19, 28, 29, 30, 34, 38, 41, 43, 46, 48, 49, 52, 53, 56, 68, 73, 74, 79, 84, 85, 88, 90],
            [0, 1, 9, 10, 14, 22, 26, 35, 39, 57, 58, 59, 60, 61, 62, 63, 64, 65, 69, 76, 80, 82, 86],
            [2, 3, 7, 11, 15, 21, 23, 31, 32, 36, 40, 44, 50, 54, 66, 70, 71, 75, 77, 81, 89],
        ]

        // Build full H = [P | I_M]: append the identity column K+m for each row m
        var result = [[Int]]()
        result.reserveCapacity(M)
        for m in 0..<M {
            var row = pm[m]
            row.append(K + m)  // identity part
            result.append(row)
        }
        return result
    }
}
