import Foundation

/// Reads a song's shape from its bass line (kick drum and bass under about 120 Hz): where the
/// beat first comes in, and where the music breaks (the bass drops out for a moment before a new
/// section). These let KnobShift start a song where it really gets going, and leave a song at a
/// natural break when its singing runs right up to the end.
enum KnobShiftSections {
    struct Result {
        let beatEntry: TimeInterval?
        let breaks: [TimeInterval]
        let steps: [String]
    }

    /// Bass loudness is judged in half second steps.
    static let step = 0.5

    /// `bass` holds one bass loudness reading per `step` seconds from the start of the song.
    static func find(bass: [Double], beats: [TimeInterval]) -> Result {
        guard bass.count > 20 else { return Result(beatEntry: nil, breaks: [], steps: ["Sections: too short to judge."]) }
        let loud = bass.sorted()[Int(Double(bass.count - 1) * 0.9)]
        guard loud > 0 else { return Result(beatEntry: nil, breaks: [], steps: ["Sections: no bass found."]) }
        let present = loud * 0.25
        let absent = loud * 0.2
        var steps: [String] = []

        // The beat comes in where the bass is present and stays present over the next 4 seconds.
        let hold = Int(4 / step)
        var entry: TimeInterval?
        for index in 0..<(bass.count - hold) where bass[index] >= present {
            if median(bass[index..<(index + hold)]) >= present {
                entry = nearest(Double(index) * step, in: beats)
                break
            }
        }
        if let entry {
            steps.append(String(format: "Beat entry: %.2fs, where the kick and bass come in and stay.", entry))
        } else {
            steps.append("Beat entry: none found, the bass never settles.")
        }

        // A break: the bass drops out for at least a second after at least 4 seconds of music.
        var breaks: [TimeInterval] = []
        var index = hold
        while index < bass.count - 1 {
            if bass[index] < absent, bass[index + 1] < absent,
               median(bass[(index - hold)..<index]) >= present {
                breaks.append(nearest(Double(index) * step, in: beats))
                while index < bass.count, bass[index] < present { index += 1 }
            }
            index += 1
        }
        steps.append(breaks.isEmpty ? "Breaks: none, the bass never drops out."
            : "Breaks: the bass drops out at " + breaks.map { String(format: "%.1fs", $0) }.joined(separator: ", ") + ".")
        return Result(beatEntry: entry, breaks: breaks, steps: steps)
    }

    /// Places a main verse on the song's phrase grid: four bar phrases counted from where the beat
    /// comes in. The vocal classifier hears a line late, by up to a bar, so the verse moves to the
    /// next phrase start when that is close; otherwise to the nearest bar.
    static func placeVerse(_ onset: TimeInterval, entry: TimeInterval, tempo: Double?, beats: [TimeInterval]) -> TimeInterval {
        guard var beatsPerMinute = tempo, beatsPerMinute > 0 else { return onset }
        while beatsPerMinute > 140 { beatsPerMinute /= 2 }
        while beatsPerMinute < 70 { beatsPerMinute *= 2 }
        let bar = 4 * 60 / beatsPerMinute
        let phrase = 4 * bar
        let phrases = max(0, ((onset - bar - entry) / phrase).rounded(.up))
        let phraseStart = entry + phrases * phrase
        if phraseStart - onset <= 1.5 * bar { return nearest(phraseStart, in: beats) }
        return nearest(entry + ((onset - entry) / bar).rounded() * bar, in: beats)
    }

    private static func nearest(_ time: TimeInterval, in beats: [TimeInterval]) -> TimeInterval {
        beats.min { abs($0 - time) < abs($1 - time) } ?? time
    }

    private static func median(_ values: ArraySlice<Double>) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}
