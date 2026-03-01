import Foundation

/// Reed-Solomon codec over GF(256) for ARDOP forward error correction.
///
/// Implements RS(255, 255−nsym) with the ARDOP primitive polynomial
/// x⁸ + x⁴ + x³ + x² + 1 (0x11D). Supports encoding and error-correcting
/// decoding via the Berlekamp-Massey algorithm and Forney's formula.
///
/// Reference: https://github.com/pflarue/ardop
final class ARDOPReedSolomon {

    // MARK: - GF(256) Tables

    /// Exponential table: expTable[i] = α^i for i in 0..<512
    private let expTable: [Int]
    /// Logarithm table: logTable[x] = log_α(x) for x in 1..<256
    private let logTable: [Int]
    /// Number of parity (check) symbols
    let nsym: Int

    /// Initialize RS codec with given number of parity symbols.
    init(nsym: Int) {
        self.nsym = nsym

        var exp = [Int](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)

        var x = 1
        for i in 0..<255 {
            exp[i] = x
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 {
                x ^= 0x11D
            }
        }
        for i in 255..<512 {
            exp[i] = exp[i - 255]
        }

        self.expTable = exp
        self.logTable = log
    }

    // MARK: - GF(256) Arithmetic

    private func gfMul(_ a: Int, _ b: Int) -> Int {
        if a == 0 || b == 0 { return 0 }
        return expTable[logTable[a] + logTable[b]]
    }

    private func gfDiv(_ a: Int, _ b: Int) -> Int {
        if a == 0 { return 0 }
        return expTable[(logTable[a] - logTable[b] + 255) % 255]
    }

    private func gfPow(_ x: Int, _ power: Int) -> Int {
        if x == 0 { return 0 }
        return expTable[(logTable[x] * power) % 255]
    }

    // MARK: - Polynomial Operations

    /// Multiply two polynomials over GF(256)
    private func polyMul(_ p: [Int], _ q: [Int]) -> [Int] {
        var result = [Int](repeating: 0, count: p.count + q.count - 1)
        for (i, pi) in p.enumerated() {
            if pi == 0 { continue }
            for (j, qj) in q.enumerated() {
                if qj == 0 { continue }
                result[i + j] ^= gfMul(pi, qj)
            }
        }
        return result
    }

    /// Evaluate polynomial at x using Horner's method
    private func polyEval(_ poly: [Int], at x: Int) -> Int {
        var result = poly[0]
        for i in 1..<poly.count {
            result = gfMul(result, x) ^ poly[i]
        }
        return result
    }

    /// Generator polynomial: ∏(x − α^i) for i in 0..<nsym
    private lazy var generatorPoly: [Int] = {
        var g = [1]
        for i in 0..<nsym {
            g = polyMul(g, [1, expTable[i]])
        }
        return g
    }()

    // MARK: - Encode

    /// Encode data bytes, appending nsym parity bytes.
    /// - Parameter data: Input data (max 255 − nsym bytes)
    /// - Returns: Data followed by nsym parity bytes
    func encode(_ data: [UInt8]) -> [UInt8] {
        let gen = generatorPoly
        let dataLen = data.count

        var msg = [Int](repeating: 0, count: dataLen + nsym)
        for (i, byte) in data.enumerated() {
            msg[i] = Int(byte)
        }

        // Systematic encoding via polynomial long division
        for i in 0..<dataLen {
            let coeff = msg[i]
            if coeff != 0 {
                for j in 1..<gen.count {
                    msg[i + j] ^= gfMul(gen[j], coeff)
                }
            }
        }

        // Remainder forms the parity bytes
        var result = data
        for i in dataLen..<(dataLen + nsym) {
            result.append(UInt8(msg[i] & 0xFF))
        }
        return result
    }

    // MARK: - Decode

    /// Decode RS-encoded message, correcting up to nsym/2 symbol errors.
    /// - Parameter message: Received codeword (data + parity)
    /// - Returns: Corrected data bytes (without parity), or nil if uncorrectable
    func decode(_ message: [UInt8]) -> [UInt8]? {
        let n = message.count
        var received = message.map { Int($0) }

        // Step 1: Compute syndromes
        var syndromes = [Int](repeating: 0, count: nsym)
        var hasErrors = false
        for i in 0..<nsym {
            syndromes[i] = polyEval(received, at: expTable[i])
            if syndromes[i] != 0 { hasErrors = true }
        }

        if !hasErrors {
            return Array(message.prefix(n - nsym))
        }

        // Step 2: Berlekamp-Massey to find error locator polynomial
        let errorLocator = berlekampMassey(syndromes)
        let numErrors = errorLocator.count - 1
        if numErrors > nsym / 2 { return nil }

        // Step 3: Chien search for error positions
        let errorPositions = chienSearch(errorLocator, length: n)
        guard errorPositions.count == numErrors else { return nil }

        // Step 4: Forney algorithm for error magnitudes
        let errorEvaluator = computeErrorEvaluator(syndromes, errorLocator: errorLocator)

        for (idx, pos) in errorPositions.enumerated() {
            let xi = expTable[n - 1 - pos]
            let xiInv = expTable[255 - (n - 1 - pos) % 255]

            // Evaluate Ω(Xi^-1)
            let omega = polyEval(errorEvaluator, at: xiInv)

            // Evaluate Λ'(Xi^-1) — formal derivative of error locator
            var lambdaPrime = 0
            for j in stride(from: 1, to: errorLocator.count, by: 2) {
                lambdaPrime ^= gfMul(errorLocator[j], gfPow(xiInv, j - 1))
            }

            if lambdaPrime == 0 { return nil }

            // Error magnitude: e_i = Xi * Ω(Xi^-1) / Λ'(Xi^-1)
            let magnitude = gfMul(xi, gfDiv(omega, lambdaPrime))
            received[pos] ^= magnitude
        }

        // Verify correction by recomputing syndromes
        for i in 0..<nsym {
            if polyEval(received, at: expTable[i]) != 0 { return nil }
        }

        return received.prefix(n - nsym).map { UInt8($0 & 0xFF) }
    }

    // MARK: - Berlekamp-Massey Algorithm

    private func berlekampMassey(_ syndromes: [Int]) -> [Int] {
        let n = syndromes.count
        var C = [Int](repeating: 0, count: n + 1)  // error locator
        var B = [Int](repeating: 0, count: n + 1)  // auxiliary
        C[0] = 1
        B[0] = 1

        var L = 0     // current number of assumed errors
        var m = 1     // shift counter
        var b = 1     // previous discrepancy

        for step in 0..<n {
            // Compute discrepancy
            var d = syndromes[step]
            for i in 1...L {
                d ^= gfMul(C[i], syndromes[step - i])
            }

            if d == 0 {
                m += 1
            } else if 2 * L <= step {
                // Complexity increase
                let T = C
                for i in 0..<(n + 1 - m) {
                    if B[i] != 0 {
                        C[i + m] ^= gfMul(gfDiv(d, b), B[i])
                    }
                }
                L = step + 1 - L
                B = T
                b = d
                m = 1
            } else {
                // No complexity increase
                for i in 0..<(n + 1 - m) {
                    if B[i] != 0 {
                        C[i + m] ^= gfMul(gfDiv(d, b), B[i])
                    }
                }
                m += 1
            }
        }

        return Array(C.prefix(L + 1))
    }

    // MARK: - Chien Search

    /// Find error positions by evaluating the error locator at all field elements.
    private func chienSearch(_ locator: [Int], length: Int) -> [Int] {
        var positions = [Int]()
        for i in 0..<length {
            let x = expTable[(255 - i) % 255]
            if polyEval(locator, at: x) == 0 {
                positions.append(length - 1 - i)
            }
        }
        return positions
    }

    // MARK: - Error Evaluator Polynomial

    /// Compute Ω(x) = S(x) · Λ(x) mod x^nsym
    private func computeErrorEvaluator(_ syndromes: [Int], errorLocator: [Int]) -> [Int] {
        // S(x) = S[0] + S[1]x + S[2]x² + ...
        var sx = [Int](repeating: 0, count: nsym + 1)
        sx[0] = 1
        for i in 0..<nsym {
            sx[i + 1] = syndromes[i]
        }

        let product = polyMul(sx, errorLocator)

        // Truncate to degree < nsym
        let resultLen = min(product.count, nsym)
        return Array(product.prefix(resultLen))
    }
}
