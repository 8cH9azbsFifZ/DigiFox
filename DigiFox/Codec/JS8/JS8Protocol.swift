import Foundation

enum JS8Speed: Int, CaseIterable, Codable, Identifiable {
    case normal = 0, fast = 1, turbo = 2, slow = 3, ultra = 4

    var id: Int { rawValue }

    var symbolSamples: Int {
        [1920, 1280, 640, 3840, 7680][rawValue]
    }

    var name: String {
        ["Normal", "Fast", "Turbo", "Slow", "Ultra"][rawValue]
    }

    var txWindow: Double {
        [15.0, 10.0, 6.0, 30.0, 120.0][rawValue]
    }
}

enum JS8Protocol {
    static let sampleRate: Double = 12000.0
    static let toneCount = 8
    static let bitsPerSymbol = 3
    static let symbolCount = 79
    static let costasLength = 7
    static let dataSymbolCount = 58
    static let codewordBits = 174
    static let messageBits = 91
    static let payloadBits = 77
    static let crcBits = 14

    static let costas: [Int] = [3, 1, 4, 0, 6, 5, 2]

    static let syncPositions: Set<Int> = Set(
        (0..<7).map { $0 } + (0..<7).map { 36 + $0 } + (0..<7).map { 72 + $0 }
    )

    static let dataPositions: [Int] = (0..<79).filter { !syncPositions.contains($0) }

    static let charset: [Character] = Array(" 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?@")
    static let charsetSize = 43

    static func toneSpacing(for speed: JS8Speed) -> Double {
        sampleRate / Double(speed.symbolSamples)
    }

    static func symbolDuration(for speed: JS8Speed) -> Double {
        Double(speed.symbolSamples) / sampleRate
    }
}
