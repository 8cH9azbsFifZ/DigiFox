import Foundation

// MARK: - Phase Definition

enum TestPhase: Equatable {
    case countdown(seconds: Int)
    case work(seconds: Int, targetKg: Float?)
    case rest(seconds: Int)
    case done

    var duration: Int {
        switch self {
        case .countdown(let s), .work(let s, _), .rest(let s): return s
        case .done: return 0
        }
    }

    var displayName: String {
        switch self {
        case .countdown: return "Countdown"
        case .work: return "Hang"
        case .rest: return "Rest"
        case .done: return "Done"
        }
    }
}

// MARK: - Test Result

struct TestResult {
    let testType: ForceSession.TestType
    let peakForceKg: Float
    let averageForceKg: Float
    let durationSeconds: Float
    let segments: [ForceSession.Segment]
    let additionalMetrics: [String: Float]
}

// MARK: - Test Protocol Definition

protocol TestProtocolDefinition {
    var name: String { get }
    var testType: ForceSession.TestType { get }
    var phases: [TestPhase] { get }
    var totalRepsPerSet: Int { get }
    var totalSetsCount: Int { get }
    var notation: String { get }
    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult
    func label(for phaseIndex: Int) -> String?
    func segmentMetadata(for phaseIndex: Int) -> [String: String]?
}

// MARK: - Segment Data Helper

struct SegmentData {
    let forces: [Float]
    let peak: Float
    let avg: Float
    let metadata: [String: String]?
}

extension TestProtocolDefinition {
    var totalRepsPerSet: Int { 0 }
    var totalSetsCount: Int { 0 }
    var notation: String { name }
    func label(for phaseIndex: Int) -> String? { nil }
    func segmentMetadata(for phaseIndex: Int) -> [String: String]? { nil }

    // MARK: - Shared Helpers

    func sessionDuration(from samples: [TindeqProtocol.ForceSample]) -> Float {
        guard let first = samples.first, let last = samples.last,
              last.timestampUs >= first.timestampUs else { return 0 }
        return Float(last.timestampUs - first.timestampUs) / 1_000_000.0
    }

    func extractWorkSegments(
        from samples: [TindeqProtocol.ForceSample],
        segments: [ForceSession.Segment]
    ) -> [SegmentData] {
        segments.filter { $0.type == .work }.compactMap { seg in
            guard seg.startIndex < samples.count else { return nil }
            let endIdx = min(seg.endIndex, samples.count - 1)
            let segSamples = Array(samples[seg.startIndex...endIdx])
            guard !segSamples.isEmpty else { return nil }
            let forces = segSamples.map(\.forceKg)
            let peak = forces.max() ?? 0
            let avg = forces.reduce(0, +) / Float(forces.count)
            return SegmentData(forces: forces, peak: peak, avg: avg, metadata: seg.metadata)
        }
    }
}

// MARK: - MVC-7 Protocol Definition

struct MVC7ProtocolDefinition: TestProtocolDefinition {
    let name = "MVC-7"
    let testType: ForceSession.TestType = .mvc7
    let attempts: Int
    let hangDuration: Int
    let restDuration: Int

    init(attempts: Int = 3, hangDuration: Int = 7, restDuration: Int = 120) {
        self.attempts = attempts
        self.hangDuration = hangDuration
        self.restDuration = restDuration
    }

    var notation: String {
        "\(attempts)x MaxHang \(hangDuration)s:\(restDuration)s"
    }

    var phases: [TestPhase] {
        var result: [TestPhase] = []
        for i in 0..<attempts {
            result.append(.countdown(seconds: 3))
            result.append(.work(seconds: hangDuration, targetKg: nil))
            if i < attempts - 1 {
                result.append(.rest(seconds: restDuration))
            }
        }
        result.append(.done)
        return result
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let segData = extractWorkSegments(from: samples, segments: segments)
        let bestPeak = segData.map(\.peak).max() ?? 0
        let allForces = segData.flatMap(\.forces)
        let avg = allForces.isEmpty ? 0 : allForces.reduce(0, +) / Float(allForces.count)

        return TestResult(
            testType: .mvc7, peakForceKg: bestPeak, averageForceKg: avg,
            durationSeconds: sessionDuration(from: samples),
            segments: segments,
            additionalMetrics: ["fmax": bestPeak, "attempts": Float(segData.count)]
        )
    }
}

// MARK: - Repeater Protocol Definition

struct RepeaterProtocolDefinition: TestProtocolDefinition {
    let name = "Repeater"
    let testType: ForceSession.TestType = .repeater
    let config: RepeatersConfig

    init(config: RepeatersConfig = RepeatersConfig()) {
        self.config = config
    }

    var notation: String {
        let work = Int(config.workS)
        let rest = Int(config.restS)
        let pause = Int(config.setPauseS)
        return "\(config.numSets)x \(config.numReps)x Hang \(work):\(rest):\(pause)s"
    }

    var totalRepsPerSet: Int { config.numReps }
    var totalSetsCount: Int { config.numSets }

    var phases: [TestPhase] {
        var result: [TestPhase] = []
        for set in 0..<config.numSets {
            for rep in 0..<config.numReps {
                if set == 0 && rep == 0 {
                    result.append(.countdown(seconds: config.countdownS))
                }
                result.append(.work(seconds: Int(config.workS), targetKg: config.targetForceKg > 0 ? config.targetForceKg : nil))
                if rep < config.numReps - 1 {
                    result.append(.rest(seconds: Int(config.restS)))
                }
            }
            if set < config.numSets - 1 {
                result.append(.rest(seconds: Int(config.setPauseS)))
            }
        }
        result.append(.done)
        return result
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let segData = extractWorkSegments(from: samples, segments: segments)
        let peaks = segData.map(\.peak)
        let bestPeak = peaks.max() ?? 0
        let allForces = segData.flatMap(\.forces)
        let avg = allForces.isEmpty ? 0 : allForces.reduce(0, +) / Float(allForces.count)
        let decay = ForceAnalysis.forceDecayPercent(firstRepPeak: peaks.first ?? 0, lastRepPeak: peaks.last ?? 0)
        let avgPeak = peaks.isEmpty ? 0 : peaks.reduce(0, +) / Float(peaks.count)

        return TestResult(
            testType: .repeater, peakForceKg: bestPeak, averageForceKg: avg,
            durationSeconds: sessionDuration(from: samples),
            segments: segments,
            additionalMetrics: ["forceDecay": decay, "totalReps": Float(segData.count), "avgPeakPerRep": avgPeak]
        )
    }
}

// MARK: - Endurance Protocol Definition

struct EnduranceProtocolDefinition: TestProtocolDefinition {
    let name = "Endurance"
    let testType: ForceSession.TestType = .endurance
    let config: EnduranceConfig

    init(config: EnduranceConfig = EnduranceConfig()) {
        self.config = config
    }

    var notation: String {
        let dur = Int(config.durationS)
        let target = Int(config.targetForceKg)
        return "Endurance \(dur)s @\(target)kg"
    }

    var phases: [TestPhase] {
        [
            .countdown(seconds: config.countdownS),
            .work(seconds: Int(config.durationS), targetKg: config.targetForceKg),
            .done
        ]
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let sessionSamples = samples.map { ForceSession.Sample(forceKg: $0.forceKg, timestampUs: $0.timestampUs) }
        let metrics = ForceAnalysis.computeEnduranceMetrics(from: sessionSamples, targetKg: config.targetForceKg)
        
        return TestResult(
            testType: .endurance, peakForceKg: metrics.peakForceKg, averageForceKg: metrics.avgForceKg,
            durationSeconds: metrics.totalDurationS, segments: segments,
            additionalMetrics: [
                "timeAboveTarget": metrics.timeAboveTargetS,
                "timeBelowTarget": metrics.timeBelowTargetS,
                "forceImpulse": metrics.forceImpulseKgS,
                "targetForce": config.targetForceKg
            ]
        )
    }
}

// MARK: - Critical Force Protocol Definition

struct CriticalForceProtocolDefinition: TestProtocolDefinition {
    let name = "Critical Force"
    let testType: ForceSession.TestType = .criticalForce
    let config: CriticalForceConfig

    init(config: CriticalForceConfig = CriticalForceConfig()) {
        self.config = config
    }

    var notation: String {
        let work = Int(config.workS)
        let rest = Int(config.restS)
        return "CF \(config.numIntervals)x \(work):\(rest)s"
    }

    var phases: [TestPhase] {
        var result: [TestPhase] = [.countdown(seconds: config.countdownS)]
        for i in 0..<config.numIntervals {
            result.append(.work(seconds: Int(config.workS), targetKg: nil))
            if i < config.numIntervals - 1 {
                result.append(.rest(seconds: Int(config.restS)))
            }
        }
        result.append(.done)
        return result
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let workSegs = segments.filter { $0.type == .work }
        var intervalAvgs: [Float] = []
        var workDurations: [Float] = []
        
        for seg in workSegs {
            guard seg.startIndex < samples.count else { continue }
            let endIdx = min(seg.endIndex, samples.count - 1)
            let segSamples = Array(samples[seg.startIndex...endIdx])
            guard segSamples.count >= 2,
                  let segFirst = segSamples.first, let segLast = segSamples.last else { continue }
            let avg = segSamples.map(\.forceKg).reduce(0, +) / Float(segSamples.count)
            let dur = segLast.timestampUs >= segFirst.timestampUs
                ? Float(segLast.timestampUs - segFirst.timestampUs) / 1_000_000.0 : 0
            intervalAvgs.append(avg)
            workDurations.append(dur)
        }
        
        let cfResult = ForceAnalysis.computeCriticalForce(intervalAvgForces: intervalAvgs, workDurations: workDurations)
        let peak = samples.map(\.forceKg).max() ?? 0
        let avg = samples.map(\.forceKg).reduce(0, +) / max(Float(samples.count), 1)
        
        return TestResult(
            testType: .criticalForce, peakForceKg: peak, averageForceKg: avg,
            durationSeconds: sessionDuration(from: samples),
            segments: segments,
            additionalMetrics: [
                "criticalForce": cfResult?.criticalForceKg ?? 0,
                "wPrime": cfResult?.wPrimeKgS ?? 0,
                "intervals": Float(workSegs.count)
            ]
        )
    }
}

// MARK: - RFD Protocol Definition

struct RFDProtocolDefinition: TestProtocolDefinition {
    let name = "RFD"
    let testType: ForceSession.TestType = .rfd
    let config: RFDConfig

    init(config: RFDConfig = RFDConfig()) {
        self.config = config
    }

    var notation: String {
        let dur = String(format: "%.0f", config.durationS)
        return "RFD \(config.attempts)x \(dur)s:\(config.restBetweenAttemptsS)s"
    }

    var phases: [TestPhase] {
        var result: [TestPhase] = []
        for i in 0..<config.attempts {
            result.append(.countdown(seconds: config.countdownS))
            result.append(.work(seconds: Int(config.durationS), targetKg: nil))
            if i < config.attempts - 1 {
                result.append(.rest(seconds: config.restBetweenAttemptsS))
            }
        }
        result.append(.done)
        return result
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let workSegs = segments.filter { $0.type == .work }
        var bestRFD: Float = 0
        var bestPeak: Float = 0
        
        for seg in workSegs {
            guard seg.startIndex < samples.count else { continue }
            let endIdx = min(seg.endIndex, samples.count - 1)
            let segSamples = Array(samples[seg.startIndex...endIdx]).map {
                ForceSession.Sample(forceKg: $0.forceKg, timestampUs: $0.timestampUs)
            }
            if let rfd = ForceAnalysis.computeRFD(from: segSamples, thresholdKg: config.thresholdKg) {
                if rfd.rfd2080KgPerS > bestRFD { bestRFD = rfd.rfd2080KgPerS }
                if rfd.peakForceKg > bestPeak { bestPeak = rfd.peakForceKg }
            }
        }
        
        return TestResult(
            testType: .rfd, peakForceKg: bestPeak, averageForceKg: 0,
            durationSeconds: sessionDuration(from: samples),
            segments: segments,
            additionalMetrics: ["rfd2080": bestRFD, "attempts": Float(workSegs.count)]
        )
    }
}

// MARK: - Free Hang Protocol (simple measurement, no timed phases)

struct FreeHangProtocolDefinition: TestProtocolDefinition {
    let name = "Free Hang"
    let testType: ForceSession.TestType = .freeHang
    let durationS: Int
    let targetKg: Float?

    init(durationS: Int = 60, targetKg: Float? = nil) {
        self.durationS = durationS
        self.targetKg = targetKg
    }

    var notation: String {
        if let t = targetKg {
            return "Hang \(durationS)s @\(Int(t))kg"
        }
        return "Hang \(durationS)s"
    }

    var phases: [TestPhase] {
        [
            .countdown(seconds: 3),
            .work(seconds: durationS, targetKg: targetKg),
            .done
        ]
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let peak = samples.map(\.forceKg).max() ?? 0
        let avg = samples.isEmpty ? 0 : samples.map(\.forceKg).reduce(0, +) / Float(samples.count)

        return TestResult(
            testType: .freeHang, peakForceKg: peak, averageForceKg: avg,
            durationSeconds: sessionDuration(from: samples), segments: segments,
            additionalMetrics: [:]
        )
    }
}

// MARK: - Warm-Up Protocol Definition

struct WarmUpProtocolDefinition: TestProtocolDefinition {
    let name = "Warm-up"
    let testType: ForceSession.TestType = .warmUp

    var notation: String {
        let s = ClimbroConstants.warmUpSets
        let r = ClimbroConstants.warmUpReps
        let w = ClimbroConstants.warmUpWorkTime
        let p = ClimbroConstants.warmUpRepRestTime
        let sp = ClimbroConstants.warmUpSetRestTime
        return "\(s)x \(r)x Hang \(w):\(p):\(sp)s (Warm-up)"
    }

    var phases: [TestPhase] {
        var result: [TestPhase] = [.countdown(seconds: 5)]
        // 2 sets x 8 reps x 5s work / 5s rest
        for set in 0..<ClimbroConstants.warmUpSets {
            for rep in 0..<ClimbroConstants.warmUpReps {
                result.append(.work(seconds: ClimbroConstants.warmUpWorkTime, targetKg: nil))
                if rep < ClimbroConstants.warmUpReps - 1 {
                    result.append(.rest(seconds: ClimbroConstants.warmUpRepRestTime))
                }
            }
            if set < ClimbroConstants.warmUpSets - 1 {
                result.append(.rest(seconds: ClimbroConstants.warmUpSetRestTime))
            }
        }
        result.append(.done)
        return result
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let peak = samples.map(\.forceKg).max() ?? 0
        let avg = samples.isEmpty ? 0 : samples.map(\.forceKg).reduce(0, +) / Float(samples.count)
        return TestResult(
            testType: .warmUp, peakForceKg: peak, averageForceKg: avg,
            durationSeconds: sessionDuration(from: samples),
            segments: segments, additionalMetrics: [:]
        )
    }
}

// MARK: - Bilateral Repeater Protocol Definition

struct BilateralRepeaterProtocolDefinition: TestProtocolDefinition {
    let name: String
    let testType: ForceSession.TestType = .repeater
    let config: RepeatersConfig

    private let _phases: [TestPhase]
    private let _labels: [String]
    private let _metadata: [[String: String]]
    private let _notation: String

    var notation: String { _notation }

    init(config: RepeatersConfig, name: String = "Bilateral Repeater") {
        self.config = config
        self.name = name

        let notation: String = {
            let work = Int(config.workS)
            let rest = Int(config.restS)
            let pause = Int(config.setPauseS)
            let pct = config.intensityPct
            return "\(config.numSets)x \(config.numReps)x Hang \(work):\(rest):\(pause)s @\(pct)% R/L"
        }()
        self._notation = notation

        let hands: [(displayName: String, code: String)] = [("Right", "R"), ("Left", "L")]
        let switchTime = Int(config.lrSwitchTimeS)
        let betweenRoundsRest = Int(config.setPauseS)

        var phases: [TestPhase] = []
        var labels: [String] = []
        var metadata: [[String: String]] = []

        for set in 0..<config.numSets {
            for (handIdx, hand) in hands.enumerated() {
                let setLabel = "\(hand.displayName) — Set \(set + 1)"

                // Rest between rounds
                if set > 0 && handIdx == 0 && betweenRoundsRest > 0 {
                    phases.append(.rest(seconds: betweenRoundsRest))
                    labels.append("⏸ Rest")
                    metadata.append(["phase": "setPause"])
                }

                // Hand switch rest (before every L block)
                if handIdx == 1 {
                    phases.append(.rest(seconds: switchTime))
                    labels.append("↔️ Switch → \(hand.displayName)")
                    metadata.append(["phase": "switch", "hand": hand.code])
                }

                // Countdown
                phases.append(.countdown(seconds: config.countdownS))
                labels.append(setLabel)
                metadata.append(["hand": hand.code, "set": "\(set + 1)"])

                // Reps
                for rep in 0..<config.numReps {
                    phases.append(.work(
                        seconds: Int(config.workS),
                        targetKg: config.targetForceKg > 0 ? config.targetForceKg : nil
                    ))
                    labels.append(setLabel)
                    metadata.append(["hand": hand.code, "set": "\(set + 1)", "rep": "\(rep + 1)"])

                    if rep < config.numReps - 1 {
                        phases.append(.rest(seconds: Int(config.restS)))
                        labels.append(setLabel)
                        metadata.append(["hand": hand.code, "set": "\(set + 1)", "rep": "\(rep + 1)"])
                    }
                }
            }
        }

        phases.append(.done)
        labels.append("")
        metadata.append([:])

        self._phases = phases
        self._labels = labels
        self._metadata = metadata
    }

    var phases: [TestPhase] { _phases }
    var totalRepsPerSet: Int { config.numReps }
    var totalSetsCount: Int { config.numSets }

    func label(for phaseIndex: Int) -> String? {
        guard phaseIndex < _labels.count else { return nil }
        let l = _labels[phaseIndex]
        return l.isEmpty ? nil : l
    }

    func segmentMetadata(for phaseIndex: Int) -> [String: String]? {
        guard phaseIndex < _metadata.count else { return nil }
        let m = _metadata[phaseIndex]
        return m.isEmpty ? nil : m
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let segData = extractWorkSegments(from: samples, segments: segments)
        let allForces = segData.flatMap(\.forces)
        let allPeaks = segData.map(\.peak)
        let leftPeaks = segData.filter { $0.metadata?["hand"] == "L" }.map(\.peak)
        let rightPeaks = segData.filter { $0.metadata?["hand"] == "R" }.map(\.peak)

        let bestPeak = allPeaks.max() ?? 0
        let avg = allForces.isEmpty ? 0 : allForces.reduce(0, +) / Float(allForces.count)
        let leftPeak = leftPeaks.max() ?? 0
        let rightPeak = rightPeaks.max() ?? 0
        let decay = ForceAnalysis.forceDecayPercent(
            firstRepPeak: allPeaks.first ?? 0,
            lastRepPeak: allPeaks.last ?? 0
        )

        return TestResult(
            testType: .repeater, peakForceKg: bestPeak, averageForceKg: avg,
            durationSeconds: sessionDuration(from: samples),
            segments: segments,
            additionalMetrics: [
                "forceDecay": decay,
                "totalReps": Float(segData.count),
                "leftPeak": leftPeak,
                "rightPeak": rightPeak,
                "bilateralIndex": rightPeak > 0 ? leftPeak / rightPeak * 100 : 0
            ]
        )
    }
}

// MARK: - Intermittent Protocol Definition (until failure)

struct IntermittentProtocolDefinition: TestProtocolDefinition {
    let name = "Intermittent"
    let testType: ForceSession.TestType = .intermittent
    let config: IntermittentConfig
    let targetForceKg: Float

    init(config: IntermittentConfig = IntermittentConfig(), fmaxKg: Float) {
        self.config = config
        self.targetForceKg = fmaxKg * config.targetPctFmax / 100.0
    }

    var notation: String {
        let work = Int(config.workS)
        let rest = Int(config.restS)
        return "Intermittent \(work):\(rest)s @\(Int(config.targetPctFmax))%Fmax until failure"
    }

    var phases: [TestPhase] {
        var result: [TestPhase] = [.countdown(seconds: config.countdownS)]
        for i in 0..<config.maxIntervals {
            result.append(.work(seconds: Int(config.workS), targetKg: targetForceKg))
            if i < config.maxIntervals - 1 {
                result.append(.rest(seconds: Int(config.restS)))
            }
        }
        result.append(.done)
        return result
    }

    var totalRepsPerSet: Int { config.maxIntervals }
    var totalSetsCount: Int { 1 }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let segData = extractWorkSegments(from: samples, segments: segments)
        let completedIntervals = segData.count

        let allForces = segData.flatMap(\.forces)
        let peak = segData.map(\.peak).max() ?? 0
        let avg = allForces.isEmpty ? 0 : allForces.reduce(0, +) / Float(allForces.count)

        let repAvgs = segData.map(\.avg)
        let decay = ForceAnalysis.forceDecayPercent(
            firstRepPeak: segData.first?.avg ?? 0,
            lastRepPeak: segData.last?.avg ?? 0
        )

        let ttf = Float(completedIntervals) * config.workS

        let enduranceIndex: Float
        if let firstAvg = repAvgs.first, firstAvg > 0, let lastAvg = repAvgs.last {
            enduranceIndex = lastAvg / firstAvg * 100
        } else {
            enduranceIndex = 0
        }

        return TestResult(
            testType: .intermittent, peakForceKg: peak, averageForceKg: avg,
            durationSeconds: sessionDuration(from: samples),
            segments: segments,
            additionalMetrics: [
                "completedIntervals": Float(completedIntervals),
                "timeToFailure": ttf,
                "targetForce": targetForceKg,
                "forceDecay": decay,
                "enduranceIndex": enduranceIndex
            ]
        )
    }
}

// MARK: - Pull-up MVC Protocol Definition

struct PullUpMVCProtocolDefinition: TestProtocolDefinition {
    let name = "Pull-up MVC"
    let testType: ForceSession.TestType = .pullUpMVC
    let config: PullUpMVCConfig

    init(config: PullUpMVCConfig = PullUpMVCConfig()) {
        self.config = config
    }

    var notation: String {
        let dur = Int(config.durationS)
        return "PU-MVC \(config.attempts)x \(dur)s:\(config.restBetweenAttemptsS)s (\(config.gripType.displayName))"
    }

    var phases: [TestPhase] {
        var result: [TestPhase] = []
        for i in 0..<config.attempts {
            result.append(.countdown(seconds: config.countdownS))
            result.append(.work(seconds: Int(config.durationS), targetKg: nil))
            if i < config.attempts - 1 {
                result.append(.rest(seconds: config.restBetweenAttemptsS))
            }
        }
        result.append(.done)
        return result
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let segData = extractWorkSegments(from: samples, segments: segments)
        let bestPeak = segData.map(\.peak).max() ?? 0
        let allForces = segData.flatMap(\.forces)
        let avg = allForces.isEmpty ? 0 : allForces.reduce(0, +) / Float(allForces.count)
        let bwRatio = config.bodyweightKg > 0 ? bestPeak / config.bodyweightKg : 0
        let addedWeight = ForceAnalysis.estimateAddedWeight(peakForceKg: bestPeak, bodyweightKg: config.bodyweightKg)

        return TestResult(
            testType: .pullUpMVC, peakForceKg: bestPeak, averageForceKg: avg,
            durationSeconds: sessionDuration(from: samples),
            segments: segments,
            additionalMetrics: [
                "pullUpPeakForce": bestPeak,
                "bodyweightRatio": bwRatio,
                "estimatedAddedWeight": addedWeight,
                "attempts": Float(segData.count)
            ]
        )
    }
}

// MARK: - Pull-up Repeater Protocol Definition

struct PullUpRepeaterProtocolDefinition: TestProtocolDefinition {
    let name = "Pull-up Repeater"
    let testType: ForceSession.TestType = .pullUpRepeater
    let config: PullUpRepeaterConfig

    init(config: PullUpRepeaterConfig = PullUpRepeaterConfig()) {
        self.config = config
    }

    var notation: String {
        let work = Int(config.workS)
        let rest = Int(config.restS)
        let pause = Int(config.setPauseS)
        let added = config.addedWeightKg > 0 ? " +\(Int(config.addedWeightKg))kg" : ""
        return "PU-Rep \(config.numSets)x\(config.numReps) \(work):\(rest):\(pause)s\(added) (\(config.gripType.displayName))"
    }

    var totalRepsPerSet: Int { config.numReps }
    var totalSetsCount: Int { config.numSets }

    var phases: [TestPhase] {
        var result: [TestPhase] = []
        for set in 0..<config.numSets {
            for rep in 0..<config.numReps {
                if set == 0 && rep == 0 {
                    result.append(.countdown(seconds: config.countdownS))
                }
                result.append(.work(seconds: Int(config.workS), targetKg: nil))
                if rep < config.numReps - 1 {
                    result.append(.rest(seconds: Int(config.restS)))
                }
            }
            if set < config.numSets - 1 {
                result.append(.rest(seconds: Int(config.setPauseS)))
            }
        }
        result.append(.done)
        return result
    }

    func label(for phaseIndex: Int) -> String? {
        nil // Phases are self-describing
    }

    func segmentMetadata(for phaseIndex: Int) -> [String: String]? {
        ["exerciseType": "pullUp", "grip": config.gripType.rawValue]
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let segData = extractWorkSegments(from: samples, segments: segments)
        let peaks = segData.map(\.peak)
        let bestPeak = peaks.max() ?? 0
        let allForces = segData.flatMap(\.forces)
        let avg = allForces.isEmpty ? 0 : allForces.reduce(0, +) / Float(allForces.count)
        let decay = ForceAnalysis.forceDecayPercent(firstRepPeak: peaks.first ?? 0, lastRepPeak: peaks.last ?? 0)
        let avgPeak = peaks.isEmpty ? 0 : peaks.reduce(0, +) / Float(peaks.count)
        let bwRatio = config.bodyweightKg > 0 ? bestPeak / config.bodyweightKg : 0

        return TestResult(
            testType: .pullUpRepeater, peakForceKg: bestPeak, averageForceKg: avg,
            durationSeconds: sessionDuration(from: samples),
            segments: segments,
            additionalMetrics: [
                "forceDecay": decay,
                "totalReps": Float(segData.count),
                "avgPeakPerRep": avgPeak,
                "bodyweightRatio": bwRatio,
                "addedWeight": config.addedWeightKg
            ]
        )
    }
}

// MARK: - Pull-up Free Protocol Definition (open measurement)

struct PullUpFreeProtocolDefinition: TestProtocolDefinition {
    let name = "Pull-up Free"
    let testType: ForceSession.TestType = .pullUpFree
    let config: PullUpFreeConfig

    init(config: PullUpFreeConfig = PullUpFreeConfig()) {
        self.config = config
    }

    var notation: String {
        let dur = Int(config.durationS)
        return "PU-Free \(dur)s (\(config.gripType.displayName))"
    }

    var phases: [TestPhase] {
        [
            .countdown(seconds: config.countdownS),
            .work(seconds: Int(config.durationS), targetKg: nil),
            .done
        ]
    }

    func computeResults(from samples: [TindeqProtocol.ForceSample], segments: [ForceSession.Segment]) -> TestResult {
        let sessionSamples = samples.map { ForceSession.Sample(forceKg: $0.forceKg, timestampUs: $0.timestampUs) }
        let detectedReps = ForceAnalysis.detectPullUpReps(from: sessionSamples)
        let metrics = ForceAnalysis.computePullUpMetrics(reps: detectedReps)
        let bwRatio = config.bodyweightKg > 0 ? metrics.peakForceKg / config.bodyweightKg : 0

        return TestResult(
            testType: .pullUpFree, peakForceKg: metrics.peakForceKg, averageForceKg: metrics.avgPeakForceKg,
            durationSeconds: sessionDuration(from: samples),
            segments: segments,
            additionalMetrics: [
                "detectedReps": Float(metrics.totalReps),
                "avgPeakPerRep": metrics.avgPeakForceKg,
                "avgRepDuration": metrics.avgRepDurationS,
                "totalImpulse": metrics.totalForceImpulseKgS,
                "fatigueIndex": metrics.fatigueIndexPct,
                "avgRFD": metrics.avgRFDKgPerS,
                "bodyweightRatio": bwRatio
            ]
        )
    }
}
