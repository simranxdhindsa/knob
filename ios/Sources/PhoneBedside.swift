import Combine
import SwiftUI
import UIKit

/// Whether the iPhone is on its charger and how full it is, watched only while the deck is up.
@MainActor
final class PhoneCharger: ObservableObject {
    static let shared = PhoneCharger()

    @Published private(set) var plugged = false
    @Published private(set) var percent: Int?
    private var watching: Set<AnyCancellable> = []
    #if DEBUG
    /// The simulator has no battery: the checks say what it would be.
    private var pretending = false
    /// The time the clock shows in the checks.
    static var checkTime: Date?
    /// A tap on the clock, for the checks. It runs the same code as a finger.
    @Published private(set) var checkTaps = 0
    #endif

    func start() {
        guard watching.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        read()
        let center = NotificationCenter.default
        Publishers.Merge(center.publisher(for: UIDevice.batteryStateDidChangeNotification),
                         center.publisher(for: UIDevice.batteryLevelDidChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.read() } }
            .store(in: &watching)
    }

    func stop() {
        watching.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func read() {
        #if DEBUG
        if pretending { return }
        #endif
        let device = UIDevice.current
        plugged = device.batteryState == .charging || device.batteryState == .full
        percent = device.batteryLevel < 0 ? nil : Int((device.batteryLevel * 100).rounded())
    }

    #if DEBUG
    func pretend(plugged: Bool, percent: Int?) {
        pretending = true
        self.plugged = plugged
        self.percent = percent
    }

    func tapClock() { checkTaps += 1 }
    #endif
}

/// The time as the clock shows it: 12 hour, with AM or PM in capitals.
struct BedsideTime: Equatable {
    let hour: Int
    let minute: Int
    let period: String
    let day: String

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hours = parts.hour ?? 0
        hour = hours % 12 == 0 ? 12 : hours % 12
        minute = parts.minute ?? 0
        period = hours < 12 ? "AM" : "PM"
        day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var spoken: String { "\(hour):\(String(format: "%02d", minute)) \(period), \(day)" }
}

/// Where the deck and the clock sit this minute: a small slow circle, so that nothing stays on
/// the same pixels all night.
enum BedsideDrift {
    private static let radius: CGFloat = 4, stops = 8

    static func offset(minute: Int) -> CGSize {
        let angle = Double(minute % stops) / Double(stops) * 2 * .pi
        return CGSize(width: radius * cos(angle), height: radius * sin(angle))
    }
}

/// The clock in Bedside mode, sized for the column beside the record: the hour over the minutes,
/// then the day, the charge and the song. Its parts rise into place one after another, and a new
/// minute rolls over.
struct PhoneBedsideClock: View {
    let song: KnobShiftModel.Track?
    let percent: Int?
    /// The height there is for it.
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    private var digits: CGFloat { min(height * 0.3, 116) }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let time = BedsideTime(shown(context.date))
            VStack(alignment: .leading, spacing: 0) {
                number(String(time.hour), value: time.hour).modifier(BedsideRise(order: 0, risen: risen))
                number(String(format: "%02d", time.minute), value: time.minute).modifier(BedsideRise(order: 1, risen: risen))
                HStack(spacing: 8) {
                    Text(time.period)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.accent)
                    Text(time.day)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Glass.secondary)
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .padding(.top, 6)
                .modifier(BedsideRise(order: 2, risen: risen))
                details
                    .padding(.top, 12)
                    .modifier(BedsideRise(order: 3, risen: risen))
            }
            .animation(reduceMotion ? nil : Motion.gentle, value: time)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(time))
            .accessibilityHint("Double tap to show the controls.")
            .accessibilityAddTraits(.isButton)
        }
        .onAppear { risen = true }
    }

    private func shown(_ date: Date) -> Date {
        #if DEBUG
        return PhoneCharger.checkTime ?? date
        #else
        return date
        #endif
    }

    private func number(_ text: String, value: Int) -> some View {
        Text(text)
            .font(.system(size: digits, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Glass.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(height: digits * 0.92, alignment: .leading)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(value)))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let percent {
                Label("\(percent)%", systemImage: "bolt.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Glass.secondary)
                    .padding(.bottom, 4)
            }
            Text(song?.name ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Glass.text)
                .lineLimit(1)
            Text(song?.artist ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Glass.secondary)
                .lineLimit(1)
        }
    }

    private func spoken(_ time: BedsideTime) -> String {
        var words = [time.spoken]
        if let percent { words.append("Battery \(percent) percent") }
        if let name = song?.name { words.append(name) }
        return words.joined(separator: ", ")
    }
}

/// One part of the clock coming up into place, a beat after the part above it.
private struct BedsideRise: ViewModifier {
    let order: Int
    let risen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(risen ? 1 : 0)
            .offset(y: risen || reduceMotion ? 0 : 14)
            .animation(Motion.bedsideRise.delay(Motion.bedsideOutSeconds + (reduceMotion ? 0 : Double(order) * Motion.bedsideStagger)), value: risen)
    }
}
