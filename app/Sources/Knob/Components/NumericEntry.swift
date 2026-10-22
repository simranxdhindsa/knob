import Foundation

enum NumericEntry {
    /// Reject malformed, non-finite and out-of-range input rather than unexpectedly raising volume.
    static func parse(_ text: String, range: ClosedRange<Double>, locale: Locale = .current) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard let value = Double(normalized), value.isFinite, range.contains(value) else { return nil }
        return value
    }
}
