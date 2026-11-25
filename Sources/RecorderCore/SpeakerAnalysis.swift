import Foundation

public struct SpeakerInterval: Codable, Equatable, Sendable {
    public let speaker: String
    public let start: Double
    public let end: Double
}

public struct VoiceClip: Codable, Sendable {
    public static let minimumDuration = 2.5
    public let interval: SpeakerInterval
    public let vector: [Float]
}

public struct SpeakerAnalysis: Codable, Sendable {
    // Change this identifier whenever the embedding model or preprocessing changes.
    public static let modelID = "community1-df2625ac-span-v1"
    public let model: String
    public let intervals: [SpeakerInterval]
    public let clips: [VoiceClip]

    /// Pick clean examples across the call. Trim edges and exclude any competing voice.
    static func sampleIntervals(_ intervals: [SpeakerInterval]) -> [SpeakerInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var candidates: [String: [SpeakerInterval]] = [:]
        var active: [SpeakerInterval] = []
        for (index, turn) in sorted.enumerated() {
            active.removeAll { $0.end <= turn.start }
            var cursor = turn.start
            func add(until end: Double) {
                let duration = min(7, end - cursor - 0.5)
                guard duration >= VoiceClip.minimumDuration else { return }
                let start = (cursor + end - duration) / 2
                candidates[turn.speaker, default: []].append(.init(speaker: turn.speaker, start: start, end: start + duration))
            }
            for prior in active where prior.speaker != turn.speaker { cursor = max(cursor, prior.end) }
            for next in sorted.dropFirst(index + 1) {
                if next.start >= turn.end { break }
                if next.speaker != turn.speaker {
                    add(until: next.start)
                    cursor = max(cursor, next.end)
                }
            }
            add(until: turn.end)
            active.append(turn)
        }
        return candidates.keys.sorted().flatMap { speaker -> [SpeakerInterval] in
            var pool = candidates[speaker, default: []].sorted {
                let a = $0.end - $0.start, b = $1.end - $1.start
                return abs(a - b) < 0.0001 ? $0.start < $1.start : a > b
            }
            var samples: [SpeakerInterval] = []
            while let best = pool.first, samples.count < 6 {
                samples.append(best)
                pool.removeAll { $0.start < best.end + 5 && $0.end > best.start - 5 }
            }
            return samples.sorted { $0.start < $1.start }
        }
    }
}

/// The timeline is sorted once. Scan just the intervals that intersect each transcript span.
struct SpeakerTimeline {
    let intervals: [SpeakerInterval]
    let maxEnd: [Double]

    init(_ intervals: [SpeakerInterval]) {
        self.intervals = intervals.sorted { $0.start < $1.start }
        var latest = 0.0
        maxEnd = self.intervals.map { latest = max(latest, $0.end); return latest }
    }

    func speaker(from start: Double, to end: Double) -> String? {
        let end = max(start + 0.02, end)
        var lower = 0, upper = intervals.count
        while lower < upper {
            let mid = (upper + lower) / 2
            if maxEnd[mid] <= start { lower = mid + 1 } else { upper = mid }
        }
        var coverage: [String: Double] = [:]
        for turn in intervals.dropFirst(lower) {
            if turn.start >= end { break }
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 { coverage[turn.speaker, default: 0] += overlap }
        }
        guard let best = coverage.max(by: { $0.value < $1.value }), best.value >= 0.55 * (end - start),
              coverage.allSatisfy({ $0.key == best.key || $0.value < min(0.18, 0.16 * (end - start)) }) else { return nil }
        return best.key
    }
}
