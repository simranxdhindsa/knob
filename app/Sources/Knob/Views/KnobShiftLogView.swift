import SwiftUI

/// KnobShift's live log, under the visualizer: grouped by song and transition, one icon per kind
/// of step, and the blend drawn as two level bars instead of rows of numbers. The full history,
/// every step included, is in knobshift.log.
struct KnobShiftLogView: View {
    @ObservedObject var model: KnobShiftModel
    var maxHeight: CGFloat
    @AppStorage(PersistKey.knobShiftLogOpen.rawValue) private var open = false

    private static let visible = 160
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm:ss a"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text("KNOBSHIFT LOG").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Screen.textTertiary)
                Spacer()
                if open {
                    Button("OPEN FILE") { model.openDiagnosticLog() }
                        .help("Open knobshift.log with every step, including each volume change")
                }
                Button(open ? "HIDE" : "SHOW") { open.toggle() }
                    .foregroundStyle(open ? Palette.accent : Screen.textSecondary)
            }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .bold)).tracking(0.6)
            .foregroundStyle(Screen.textSecondary)
            if open { screen }
        }
    }

    private var screen: some View {
        let rows = Self.collapsed(Array(model.diagnostics.suffix(Self.visible)))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(rows) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .onAppear { proxy.scrollTo(rows.last?.id, anchor: .bottom) }
            .onChange(of: model.diagnostics.last?.id) { _, _ in
                proxy.scrollTo(Self.collapsed(Array(model.diagnostics.suffix(Self.visible))).last?.id, anchor: .bottom)
            }
        }
        .frame(minHeight: 70, maxHeight: max(70, maxHeight))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: [Screen.top, Screen.bottom], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Screen.edge, lineWidth: 1))
    }

    @ViewBuilder private func row(_ entry: KnobShiftModel.Diagnostic) -> some View {
        if entry.isSection {
            HStack(spacing: 8) {
                Text(entry.message.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(0.7)
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
                Rectangle().fill(Screen.textTertiary.opacity(0.35)).frame(height: 1)
            }
            .padding(.top, 6)
        } else if let blend = entry.blend {
            blendRow(entry, blend)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: Self.icon(entry.stage))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Self.isLoud(entry.stage) ? Palette.accent : Screen.textSecondary)
                    .frame(width: 12)
                message(entry)
                Spacer(minLength: 4)
                Text(Self.formatter.string(from: entry.timestamp))
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(Screen.textTertiary)
            }
        }
    }

    /// "Label: detail" lines get a bold label, so analysis steps scan like a spec sheet.
    private func message(_ entry: KnobShiftModel.Diagnostic) -> some View {
        let text = entry.message
        let color = entry.stage == "ERROR" ? Palette.accent : Screen.text
        let parts = text.split(separator: ":", maxSplits: 1)
        let labelled = parts.count == 2 && parts[0].count <= 24 && !parts[0].contains(" at ")
        return Group {
            if labelled {
                Text(String(parts[0])).font(.system(size: 10, weight: .bold)).foregroundColor(color)
                    + Text(":" + String(parts[1])).font(.system(size: 10)).foregroundColor(Screen.textSecondary)
            } else {
                Text(text).font(.system(size: 10)).foregroundColor(color)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func blendRow(_ entry: KnobShiftModel.Diagnostic, _ blend: KnobShiftModel.Diagnostic.Blend) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: Self.icon(entry.stage))
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 12)
                Text(String(format: "Blending, %.0f%% done", blend.progress * 100))
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(Screen.text)
                Spacer()
            }
            level("OUT", blend.outgoing, lit: false)
            level("IN", blend.incoming, lit: true)
        }
        .padding(.leading, 19)
        .padding(.trailing, 4)
    }

    private func level(_ label: String, _ value: Double, lit: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 8, weight: .bold)).tracking(0.5)
                .foregroundStyle(Screen.textTertiary).frame(width: 22, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Screen.grid)
                    Capsule().fill(lit ? Palette.accent : Screen.bar)
                        .frame(width: geometry.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 4)
            Text(String(format: "%.2f", value)).font(.system(size: 8, weight: .medium).monospacedDigit())
                .foregroundStyle(Screen.textSecondary).frame(width: 26, alignment: .trailing)
        }
    }

    /// A blend logs a level reading every few percent; on screen only the latest one of each run
    /// is kept, so the meter moves in place instead of filling the log.
    private static func collapsed(_ entries: [KnobShiftModel.Diagnostic]) -> [KnobShiftModel.Diagnostic] {
        var result: [KnobShiftModel.Diagnostic] = []
        for entry in entries {
            if entry.blend != nil, result.last?.blend != nil { result.removeLast() }
            result.append(entry)
        }
        return result
    }

    private static func isLoud(_ stage: String) -> Bool {
        stage == "KNOBMIX" || stage == "ERROR"
    }

    private static func icon(_ stage: String) -> String {
        switch stage {
        case "ANALYSIS": "waveform"
        case "PLAN": "point.topleft.down.to.point.bottomright.curvepath"
        case "TIMING": "clock"
        case "KNOBMIX": "arrow.left.arrow.right"
        case "DECK": "opticaldisc"
        case "HANDOFF": "arrow.right.to.line"
        case "ENGINE", "DEVICE": "hifispeaker"
        case "PLAY": "play.fill"
        case "STOP": "stop.fill"
        case "SEEK", "TRANSPORT": "forward.fill"
        case "IMPORT", "QUEUE", "READY": "music.note.list"
        case "RESTORE": "arrow.clockwise"
        case "SESSION", "CHECK": "power"
        case "ERROR": "exclamationmark.triangle.fill"
        default: "circle.fill"
        }
    }
}
