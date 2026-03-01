import Foundation

/// LDPC(174,91) encoder and decoder for FT8.
///
/// Uses the reference C implementation from kgoba/ft8_lib (MIT license).
/// Encoding: systematic — the first 91 bits are the message, the remaining 83 are parity.
/// Decoding: sum-product belief propagation via bp_decode() from ft8_lib.
enum LDPC {

    // MARK: - Constants

    static let N = 174   // codeword length
    static let K = 91    // message length (payload + CRC)
    static let M = 83    // parity bits (N - K)
    static let maxIterations: Int32 = 25

    static let K_BYTES = 12  // (91 + 7) / 8

    // MARK: - Encode

    /// Encode 91 message bits → 174 codeword bits using the generator matrix.
    static func encode(_ message: [UInt8]) -> [UInt8] {
        precondition(message.count == K)
        var codeword = [UInt8](repeating: 0, count: N)

        // Systematic part: first K bits are the message
        for i in 0..<K {
            codeword[i] = message[i]
        }

        // Pack message bits into bytes for bitwise AND with generator matrix
        var packed = [UInt8](repeating: 0, count: K_BYTES)
        for i in 0..<K {
            if message[i] != 0 {
                packed[i / 8] |= UInt8(0x80 >> (i % 8))
            }
        }

        // Parity bits via C generator matrix (83 rows × 12 bytes)
        var gen = kFTX_LDPC_generator
        withUnsafeBytes(of: &gen) { rawBuffer in
            for m in 0..<M {
                var parity: UInt8 = 0
                for j in 0..<K_BYTES {
                    let bits = packed[j] & rawBuffer[m * K_BYTES + j]
                    parity ^= parity8(bits)
                }
                codeword[K + m] = parity & 1
            }
        }

        return codeword
    }

    private static func parity8(_ x: UInt8) -> UInt8 {
        var v = x
        v ^= v >> 4
        v ^= v >> 2
        v ^= v >> 1
        return v & 1
    }

    // MARK: - Decode (via ft8_lib C implementation)

    /// Decode soft channel LLRs (174 values) → 91 message bits.
    /// LLR convention: positive = more likely bit 0.
    /// Returns nil if decoding fails (no valid codeword found).
    static func decode(_ llr: [Float]) -> [UInt8]? {
        precondition(llr.count == N)

        // ft8_lib bp_decode expects: positive = more likely bit 1
        // Our convention: positive = more likely bit 0
        // → negate the LLRs
        var codeword = llr.map { -$0 }

        // Normalize LLR variance to 24.0 (critical for decoder convergence)
        normalizeLLR(&codeword)

        var plain = [UInt8](repeating: 0, count: N)
        var errors: Int32 = Int32(M)

        bp_decode(&codeword, maxIterations, &plain, &errors)

        if errors > 0 {
            return nil
        }

        return Array(plain[0..<K])
    }

    /// Normalize LLR variance to 24.0 — from ft8_lib's ftx_normalize_logl.
    private static func normalizeLLR(_ log174: inout [Float]) {
        var sum: Float = 0
        var sum2: Float = 0
        for v in log174 {
            sum += v
            sum2 += v * v
        }
        let invN: Float = 1.0 / Float(N)
        let variance = (sum2 - sum * sum * invN) * invN
        guard variance > 1e-10 else { return }
        let normFactor = sqrtf(24.0 / variance)
        for i in 0..<N {
            log174[i] *= normFactor
        }
    }
}

