import SwiftUI

/// A Spotify download's progress in one line: "12 of 340" with the song spotDL is on now, and a
/// thin orange bar under it. Used in the Spotify sheet and in the queue's playlist rows, so both
/// read the same way. While it waits behind another playlist it says so instead.
struct KnobShiftImportBar: View {
    @Environment(\.surface) private var surface
    let progress: KnobShiftImport.Progress
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            Text(Self.summary(progress))
                .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                .foregroundStyle(progress.started ? Palette.accent : surface.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(surface.fill)
                    Capsule().fill(Palette.accent)
                        .frame(width: max(progress.finished > 0 ? 3 : 0, box.size.width * progress.fraction))
                        .shadow(color: Palette.accentGlow.opacity(0.5), radius: 3)
                }
            }
            .frame(height: compact ? 2 : 3)
            .animation(Motion.gentle, value: progress.finished)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(progress))
        .accessibilityValue("\(Int((progress.fraction * 100).rounded())) percent")
    }

    static func summary(_ progress: KnobShiftImport.Progress) -> String {
        guard progress.started else {
            return "Waiting for another download, \(progress.total) song\(progress.total == 1 ? "" : "s")"
        }
        let count = "\(progress.finished) of \(progress.total)"
        guard let first = progress.current.first else { return "\(count), finishing" }
        let more = progress.current.count - 1
        return "\(count). Downloading \(first)" + (more > 0 ? " and \(more) more" : "")
    }
}
