import Foundation

/// How a move from one song to the next will feel, by tempo. The limits are KnobMix's own
/// (`KnobShiftSync`): within 8% the old song eases into the new tempo without being noticed,
/// up to 20% the mix still locks but stretches, further apart is a big jump.
enum KnobShiftMixJump: Equatable {
    case smooth, stretch, big, unknown

    /// Plain words for a tooltip or a small label.
    var title: String {
        switch self {
        case .smooth: "Smooth mix"
        case .stretch: "Stretched mix"
        case .big: "Big tempo jump"
        case .unknown: "Tempo not read yet"
        }
    }
}

/// Mix Order: arranges the songs after the playing one so neighbours mix well. Pure maths on
/// tempo, with no model, no audio and no files, so it can be checked on its own.
///
/// Tempo is compared the way KnobMix compares it: the next song counts at its own, double or
/// half tempo, whichever is closest, so 75 and 150 BPM are close. The analysis holds no musical
/// key, so only tempo is used.
enum KnobShiftMixOrder {
    /// How far apart two tempos are, in octaves (0.1 is about 7%), counting half and double
    /// time as close. Nil when either tempo is missing.
    static func distance(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b, a > 0, b > 0 else { return nil }
        let ratio = log2(b / a)
        return min(abs(ratio), abs(ratio - 1), abs(ratio + 1))
    }

    /// Same matching as `KnobShiftSync.make`: the incoming tempo as its own, double or half,
    /// then the gap as a fraction of the outgoing tempo.
    static func jump(from outgoing: Double?, to incoming: Double?) -> KnobShiftMixJump {
        guard let a = outgoing, let b = incoming, a > 0, b > 0 else { return .unknown }
        let matched = [b, b * 2, b / 2].min { abs(log($0 / a)) < abs(log($1 / a)) } ?? b
        let gap = abs(matched / a - 1)
        if gap <= KnobShiftSync.outgoingStretch { return .smooth }
        return gap <= KnobShiftSync.throwStretch ? .stretch : .big
    }

    static func jump(from outgoing: KnobShiftModel.Analysis, to incoming: KnobShiftModel.Analysis) -> KnobShiftMixJump {
        jump(from: outgoing.tempo, to: incoming.tempo)
    }

    /// The songs in the new order. Songs before `playingIndex` and the playing song stay as
    /// they are; the rest are arranged. With no playing song the first song stays first and is
    /// the starting point. Songs without a tempo follow in their current order.
    static func arranged(_ tracks: [KnobShiftModel.Track], playingIndex: Int?) -> [KnobShiftModel.Track] {
        guard tracks.count > 2 else { return tracks }
        let anchor = min(max(playingIndex ?? 0, 0), tracks.count - 1)
        return arrangedIndices(tempos: tracks.map(\.analysis.tempo), anchor: anchor).map { tracks[$0] }
    }

    /// The same on bare tempos: every index 0..<count once, in the new order.
    static func arrangedIndices(tempos: [Double?], anchor: Int) -> [Int] {
        let count = tempos.count
        guard count > 2, anchor >= 0, anchor < count else { return Array(0..<count) }
        let after = Array((anchor + 1)..<count)
        let known = after.filter { (tempos[$0] ?? 0) > 0 }
        let unknown = after.filter { (tempos[$0] ?? 0) <= 0 }
        return Array(0...anchor) + chain(known, start: tempos[anchor], tempos: tempos) + unknown
    }

    /// Nearest song first, then smoothed by reversing stretches that shorten the big jumps.
    /// The song before the chain has no tempo: the chain then starts at its first song.
    private static func chain(_ songs: [Int], start: Double?, tempos: [Double?]) -> [Int] {
        guard songs.count > 1 else { return songs }
        // Tempos as octaves (log2), worked out once, so the loops below are plain arithmetic.
        let octaves = songs.map { log2(tempos[$0] ?? 1) }
        let origin: Double? = (start ?? 0) > 0 ? log2(start!) : nil
        @inline(__always) func gap(_ a: Double, _ b: Double) -> Double {
            // Plain comparisons: this runs about a million times for a long queue.
            var r = b - a
            if r < 0 { r = -r }
            return r < 0.5 ? r : (r > 1 ? r - 1 : 1 - r)
        }

        var left = Array(songs.indices), path: [Int] = []
        path.reserveCapacity(songs.count)
        var from = origin
        while !left.isEmpty {
            var best = 0
            if let from {
                var bestGap = Double.infinity
                for slot in left.indices {
                    let d = gap(from, octaves[left[slot]])
                    if d < bestGap - 1e-12 { bestGap = d; best = slot }
                }
            }
            let picked = left.remove(at: best)
            path.append(picked)
            from = octaves[picked]
        }

        // 2-opt on squared gaps, so one big jump costs more than several small ones.
        var line = path.map { octaves[$0] }
        @inline(__always) func cost(_ a: Double, _ b: Double) -> Double { let d = gap(a, b); return d * d }
        let n = line.count
        let window = 80  // reversals stay local, so a long queue costs a few passes, not n squared
        for _ in 0..<3 {
            var improved = false
            for i in 0..<n - 1 {
                for j in i + 1..<min(n, i + window) {
                    let hasPrevious = i > 0 || origin != nil
                    let previous = i > 0 ? line[i - 1] : (origin ?? 0)
                    var before = 0.0, after = 0.0
                    if hasPrevious { before += cost(previous, line[i]); after += cost(previous, line[j]) }
                    if j + 1 < n { before += cost(line[j], line[j + 1]); after += cost(line[i], line[j + 1]) }
                    if after < before - 1e-12 {
                        path[i...j].reverse()
                        line[i...j].reverse()
                        improved = true
                    }
                }
            }
            if !improved { break }
        }
        return path.map { songs[$0] }
    }
}
