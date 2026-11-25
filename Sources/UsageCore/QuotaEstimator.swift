import Darwin
import Foundation

public struct QuotaCapacityEstimate: Sendable, Equatable {
    public let fullCostUSD: Double
    public let fullTokens: Int
    public let isBlendedWithPrior: Bool
    public let usedPriorOnly: Bool
    public let sampleCount: Int

    public init(
        fullCostUSD: Double,
        fullTokens: Int,
        isBlendedWithPrior: Bool = false,
        usedPriorOnly: Bool = false,
        sampleCount: Int = 0
    ) {
        self.fullCostUSD = fullCostUSD
        self.fullTokens = fullTokens
        self.isBlendedWithPrior = isBlendedWithPrior
        self.usedPriorOnly = usedPriorOnly
        self.sampleCount = sampleCount
    }
}

/// Hybrid full-capacity quota estimator combining:
/// 1. Monotonic active-cycle sampling + mid-cycle reset detection
/// 2. Theil-Sen median slope (Δcost / Δu) resistant to cross-device/web usage offsets
/// 3. Cross-cycle Empirical Bayes shrinkage (`w = u / (u + u0)`) with multi-point regime-shift bypass
public final class QuotaEstimator: @unchecked Sendable {
    public struct Sample: Codable, Sendable, Equatable {
        public let u: Double
        public let costUSD: Double
        public let tokens: Int
        public let requests: Int

        public init(u: Double, costUSD: Double, tokens: Int, requests: Int) {
            self.u = u
            self.costUSD = costUSD
            self.tokens = tokens
            self.requests = requests
        }
    }

    private struct WindowState: Codable, Equatable {
        var resetEpoch: Double
        var samples: [Sample]
        var priorCostUSD: Double?
        var priorTokens: Int?
        var lastUsed: Double
        var lastRequests: Int
        var lastCostUSD: Double
        var lastTokens: Int
    }

    private struct StorageFile: Codable {
        var version: Int
        var windows: [String: WindowState]
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private static let maxSamples = 40
    private static let sampleMinStep = 0.002
    private static let midCycleBounceDelta = 0.005
    private static let resetShiftSeconds: TimeInterval = 120
    private static let shiftHighRatio = 1.45
    private static let shiftLowRatio = 0.68

    // Weekly window calibration constants
    private static let coldMinUsed = 0.02
    private static let coldMinReqs = 5
    private static let soloMinUsed = 0.05
    private static let warmMinUsed = 0.01
    private static let priorShrinkU0 = 0.025
    private static let slopeMinSpan = 0.02
    private static let slopeMinPairDu = 0.004
    private static let shiftMinUsed = 0.03
    private static let shiftMinReqs = 8
    private static let priorUpdateMinUsed = 0.08
    private static let priorUpdateMinReqs = 10

    public static var defaultCalibrationURL: URL {
        UsageLedger.defaultStorageDirectory
            .appendingPathComponent("usage-monitor-quota-calibration-v1.json", isDirectory: false)
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var windows: [String: WindowState] = [:]
    private var loaded = false
    private var readOnlyFutureVersion = false

    public init(fileURL: URL? = QuotaEstimator.defaultCalibrationURL) {
        self.fileURL = fileURL
    }

    /// Computes Theil-Sen median slope `median(Δv / Δu)` over all pairs with `du > 0 && du >= minPairDu`.
    public static func computeTheilSenSlope(
        samples: [Sample],
        livePoint: Sample?,
        minSpan: Double = 0.02,
        minPairDu: Double = 0.004,
        value: (Sample) -> Double
    ) -> Double? {
        var pts = samples.filter { $0.u.isFinite && $0.u > 0 && value($0).isFinite && value($0) > 0 }
        if let live = livePoint, live.u.isFinite, live.u > 0, value(live).isFinite, value(live) > 0 {
            if let last = pts.last {
                if live.u > last.u + 1e-6 {
                    pts.append(live)
                }
            } else {
                pts.append(live)
            }
        }
        guard pts.count >= 3 else { return nil }
        let spanU = pts[pts.count - 1].u - pts[0].u
        guard spanU >= minSpan else { return nil }

        let effectiveMinDu = max(1e-9, minPairDu)
        var slopes: [Double] = []
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let du = pts[j].u - pts[i].u
                let dv = value(pts[j]) - value(pts[i])
                if du > 0 && du >= effectiveMinDu && dv > 0 {
                    let slope = dv / du
                    if slope.isFinite {
                        slopes.append(slope)
                    }
                }
            }
        }
        guard slopes.count >= 2 else { return nil }
        return median(slopes)
    }

    /// Records the latest weekly observation (when `recordObservation == true` and non-stale)
    /// and returns the calibrated full-week capacity estimate.
    public func observeAndEstimateWeekly(
        accountKey: String,
        resetTime: Date?,
        usedFraction: Double,
        spentCostUSD: Double,
        spentTokens: Int,
        requestCount: Int,
        recordObservation: Bool = true,
        fallbackPriorCostUSD: Double? = nil,
        fallbackPriorTokens: Int? = nil
    ) -> QuotaCapacityEstimate? {
        lock.lock()
        defer { lock.unlock() }

        let canPersist = loadIfNeeded()

        let normalizedAccount = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "\(normalizedAccount.isEmpty ? "default" : normalizedAccount)|weekly"
        let resetEpoch = resetTime?.timeIntervalSince1970 ?? 0

        var dirty = false
        var state = windows[key] ?? WindowState(
            resetEpoch: resetEpoch,
            samples: [],
            priorCostUSD: (fallbackPriorCostUSD ?? 0) > 0 ? fallbackPriorCostUSD : nil,
            priorTokens: (fallbackPriorTokens ?? 0) > 0 ? fallbackPriorTokens : nil,
            lastUsed: 0,
            lastRequests: 0,
            lastCostUSD: 0,
            lastTokens: 0
        )

        // Seed prior from legacy fallback if state doesn't have one yet.
        if state.priorCostUSD == nil, let fb = fallbackPriorCostUSD, fb > 0 {
            state.priorCostUSD = fb
            if let fbt = fallbackPriorTokens, fbt > 0 { state.priorTokens = fbt }
            dirty = true
        }

        // Ignore late out-of-order observations from an older cycle (strict monotonic cycle forward progression).
        if resetEpoch > 0 && state.resetEpoch > 0 && resetEpoch < state.resetEpoch - Self.resetShiftSeconds {
            if let priorCost = state.priorCostUSD, priorCost > 0 {
                return QuotaCapacityEstimate(
                    fullCostUSD: priorCost,
                    fullTokens: state.priorTokens ?? 0,
                    isBlendedWithPrior: false,
                    usedPriorOnly: true,
                    sampleCount: state.samples.count
                )
            }
            return nil
        }

        // Detect forward cycle rollover -> archive previous cycle into Empirical Bayes prior.
        if recordObservation && resetEpoch > 0 && state.resetEpoch > 0 && resetEpoch > state.resetEpoch + Self.resetShiftSeconds {
            if state.lastUsed >= Self.priorUpdateMinUsed && state.lastRequests >= Self.priorUpdateMinReqs && state.lastCostUSD > 0 {
                let prevSlope = Self.computeTheilSenSlope(samples: state.samples, livePoint: nil, value: \.costUSD)
                let prevCostEst = prevSlope ?? (state.lastCostUSD / state.lastUsed)
                let prevTokSlope = Self.computeTheilSenSlope(samples: state.samples, livePoint: nil, value: { Double($0.tokens) })
                let prevTokEst = prevTokSlope ?? (Double(state.lastTokens) / state.lastUsed)
                if prevCostEst.isFinite && prevCostEst > 0 {
                    if let oldPrior = state.priorCostUSD, oldPrior > 0 {
                        state.priorCostUSD = 0.5 * oldPrior + 0.5 * prevCostEst
                    } else {
                        state.priorCostUSD = prevCostEst
                    }
                    if prevTokEst.isFinite && prevTokEst > 0 {
                        if let oldTok = state.priorTokens, oldTok > 0 {
                            state.priorTokens = Int((0.5 * Double(oldTok) + 0.5 * prevTokEst).rounded())
                        } else {
                            state.priorTokens = Int(prevTokEst.rounded())
                        }
                    }
                }
            }
            state.resetEpoch = resetEpoch
            state.samples = []
            state.lastUsed = 0
            state.lastRequests = 0
            state.lastCostUSD = 0
            state.lastTokens = 0
            dirty = true
        } else if recordObservation && resetEpoch > 0 && state.resetEpoch == 0 {
            state.resetEpoch = resetEpoch
            dirty = true
        }

        let liveSample: Sample?
        var didMidCycleBounce = false
        if usedFraction.isFinite && usedFraction > 0 && usedFraction <= 1.0 && spentCostUSD.isFinite && spentCostUSD > 0 {
            let sample = Sample(u: usedFraction, costUSD: spentCostUSD, tokens: max(0, spentTokens), requests: max(0, requestCount))
            liveSample = sample

            if recordObservation {
                if let last = state.samples.last, sample.u < last.u - Self.midCycleBounceDelta {
                    // Mid-cycle quota bounce/reset: restart slope sampling from current anchor.
                    state.samples = [sample]
                    didMidCycleBounce = true
                    dirty = true
                } else if state.samples.isEmpty || (sample.u >= (state.samples.last?.u ?? 0) + Self.sampleMinStep && sample.costUSD >= (state.samples.last?.costUSD ?? 0)) {
                    state.samples.append(sample)
                    if state.samples.count > Self.maxSamples {
                        state.samples = Self.thinSamples(state.samples, limit: Self.maxSamples)
                    }
                    dirty = true
                }

                if sample.u != state.lastUsed || sample.requests != state.lastRequests || abs(sample.costUSD - state.lastCostUSD) > 0.01 {
                    state.lastUsed = sample.u
                    state.lastRequests = sample.requests
                    state.lastCostUSD = sample.costUSD
                    state.lastTokens = sample.tokens
                    dirty = true
                }
            }
        } else {
            liveSample = nil
        }

        windows[key] = state
        if dirty && canPersist && !readOnlyFutureVersion {
            save()
        }

        let effectivePriorCost = state.priorCostUSD
        let effectivePriorTokens = state.priorTokens

        // Compute active-cycle estimates: distinguish multi-point Theil-Sen slope from single-point ratio.
        var slopeCost: Double? = nil
        var activeCostEst: Double? = nil
        var activeTokEst: Double? = nil
        if let live = liveSample {
            slopeCost = Self.computeTheilSenSlope(
                samples: state.samples,
                livePoint: recordObservation ? live : nil,
                minSpan: Self.slopeMinSpan,
                minPairDu: Self.slopeMinPairDu,
                value: \.costUSD
            )
            let ratioCost = live.costUSD / live.u
            // After a mid-cycle quota bounce, avoid raw full-week ratio until a fresh multi-point slope forms.
            activeCostEst = slopeCost ?? (didMidCycleBounce ? nil : ratioCost)

            let slopeTok = Self.computeTheilSenSlope(
                samples: state.samples,
                livePoint: recordObservation ? live : nil,
                minSpan: Self.slopeMinSpan,
                minPairDu: Self.slopeMinPairDu,
                value: { Double($0.tokens) }
            )
            activeTokEst = slopeTok ?? (didMidCycleBounce ? nil : (Double(live.tokens) / live.u))
        }

        // Case 1: Warm-start (historical prior available)
        if let priorCost = effectivePriorCost, priorCost > 0 {
            guard let live = liveSample, let activeCost = activeCostEst, live.u >= Self.warmMinUsed else {
                return QuotaCapacityEstimate(
                    fullCostUSD: priorCost,
                    fullTokens: effectivePriorTokens ?? 0,
                    isBlendedWithPrior: false,
                    usedPriorOnly: true,
                    sampleCount: state.samples.count
                )
            }

            // Regime-shift bypass requires an established multi-point Theil-Sen slope (`slopeCost != nil`)
            // so a single-point cross-device offset or stale snapshot can NEVER discard a valid prior.
            if let slope = slopeCost {
                let ratio = slope / priorCost
                let isRegimeShift = live.u >= Self.shiftMinUsed
                    && live.requests >= Self.shiftMinReqs
                    && (ratio > Self.shiftHighRatio || ratio < Self.shiftLowRatio)
                if isRegimeShift {
                    let estTokens = Int((activeTokEst ?? Double(effectivePriorTokens ?? 0)).rounded())
                    return QuotaCapacityEstimate(
                        fullCostUSD: max(slope, live.costUSD),
                        fullTokens: max(estTokens, live.tokens),
                        isBlendedWithPrior: false,
                        usedPriorOnly: false,
                        sampleCount: state.samples.count
                    )
                }
            } else if (activeCost / priorCost) < Self.shiftLowRatio {
                // Without a multi-point slope, a raw cost/u ratio far below prior is the classic
                // cross-device offset signature (high account u, low local spend): stay anchored to prior.
                return QuotaCapacityEstimate(
                    fullCostUSD: max(priorCost, live.costUSD),
                    fullTokens: max(effectivePriorTokens ?? 0, live.tokens),
                    isBlendedWithPrior: true,
                    usedPriorOnly: false,
                    sampleCount: state.samples.count
                )
            }

            // Empirical Bayes shrinkage toward prior: weight grows smoothly with u,
            // capped when only a single-point ratio (no multi-point slope yet) is available.
            let rawW = live.u / (live.u + Self.priorShrinkU0)
            let w = (slopeCost != nil) ? rawW : min(rawW, 0.35)
            let blendedCost = w * activeCost + (1.0 - w) * priorCost
            let priorTok = Double(effectivePriorTokens ?? 0)
            let blendedTok = priorTok > 0 && activeTokEst != nil
                ? (w * activeTokEst! + (1.0 - w) * priorTok)
                : (activeTokEst ?? priorTok)

            return QuotaCapacityEstimate(
                fullCostUSD: max(blendedCost, live.costUSD),
                fullTokens: max(Int(blendedTok.rounded()), live.tokens),
                isBlendedWithPrior: true,
                usedPriorOnly: false,
                sampleCount: state.samples.count
            )
        }

        // Case 2: Cold-start (no historical prior yet)
        if let live = liveSample, let activeCost = activeCostEst {
            let qualifies = (live.u >= Self.coldMinUsed && live.requests >= Self.coldMinReqs)
                || live.u >= Self.soloMinUsed
            if qualifies {
                let estTokens = Int((activeTokEst ?? 0).rounded())
                return QuotaCapacityEstimate(
                    fullCostUSD: max(activeCost, live.costUSD),
                    fullTokens: max(estTokens, live.tokens),
                    isBlendedWithPrior: false,
                    usedPriorOnly: false,
                    sampleCount: state.samples.count
                )
            }
        }

        return nil
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) * 0.5
    }

    public static func thinSamples(_ samples: [Sample], limit: Int) -> [Sample] {
        guard samples.count > limit, limit >= 2 else { return samples }
        var out: [Sample] = [samples[0]]
        let inner = limit - 2
        let lastIdx = samples.count - 1
        if inner > 0 {
            for i in 1...inner {
                let idx = Int((Double(i * lastIdx) / Double(inner + 1)).rounded())
                let item = samples[idx]
                if item != out.last {
                    out.append(item)
                }
            }
        }
        if samples[lastIdx] != out.last {
            out.append(samples[lastIdx])
        }
        return out
    }

    /// Returns `true` when safe to persist back to disk; returns `false` on symlink/transient read errors or future schema.
    private func loadIfNeeded() -> Bool {
        if loaded { return !readOnlyFutureVersion }
        guard let fileURL else {
            loaded = true
            return false
        }

        var st = stat()
        if lstat(fileURL.path, &st) != 0 {
            if errno == ENOENT {
                loaded = true
                return true
            }
            return false
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            return false
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return false
        }

        if let decoded = try? JSONDecoder().decode(StorageFile.self, from: data) {
            if decoded.version == 1 {
                self.windows = decoded.windows
                loaded = true
                return true
            }
            if decoded.version > 1 {
                self.readOnlyFutureVersion = true
                loaded = true
                return false
            }
        } else if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), probe.version > 1 {
            self.readOnlyFutureVersion = true
            loaded = true
            return false
        }

        // Back up corrupt calibration file before starting clean.
        let backupURL = URL(fileURLWithPath: "\(fileURL.path).corrupt-\(Int(Date().timeIntervalSince1970)).bak")
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        loaded = true
        return true
    }

    private func save() {
        guard let fileURL else { return }
        let payload = StorageFile(version: 1, windows: windows)
        guard let data = try? JSONEncoder().encode(payload) else { return }

        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        var st = stat()
        if lstat(fileURL.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
            return
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Non-fatal: keep in-memory calibration state intact.
        }
    }
}
