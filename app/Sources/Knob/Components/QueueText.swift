import Foundation

/// Splits a stored song title into the song name and where it is from, for display only.
/// `Rabb Khair Kare (From "Manje Bistre")` shows as "Rabb Khair Kare" with "Manje Bistre" on the
/// second line, so cutting a long title off never loses the useful part. Stored names stay as
/// they are. Only a group that starts with "From" counts as a source: `(Remix)`, `(Live)` and
/// `[Acoustic]` stay in the name.
enum SongTitle {
    struct Parts: Equatable {
        var name: String
        var source: String?
    }

    static func split(_ title: String) -> Parts {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parts = bracketed(trimmed) ?? dashed(trimmed) { return parts }
        return Parts(name: trimmed, source: nil)
    }

    /// For a song the app split as "Title - Artist": `Shokeen - From "Rabb Da Radio"` becomes a
    /// name "Shokeen" and an "artist" of `From "Rabb Da Radio"`, which is really the source.
    static func parts(name: String, artist: String?) -> (name: String, source: String?, artist: String?) {
        let own = split(name)
        if own.source != nil { return (own.name, own.source, artist) }
        if let artist, let source = fromText(artist) { return (own.name, source, nil) }
        return (own.name, nil, artist)
    }

    /// `(From "X")`, `[From X]`, `(from 'X')`, anywhere in the title, with brackets that may nest.
    private static func bracketed(_ title: String) -> Parts? {
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]")]
        for (open, close) in pairs {
            var search = title.startIndex..<title.endIndex
            while let found = title.range(of: "\(open)from ", options: [.caseInsensitive, .backwards], range: search) {
                var depth = 0
                var end: String.Index?
                var i = found.lowerBound
                while i < title.endIndex {
                    if title[i] == open { depth += 1 } else if title[i] == close {
                        depth -= 1
                        if depth == 0 { end = i; break }
                    }
                    i = title.index(after: i)
                }
                if let end {
                    let inner = String(title[found.upperBound..<end])
                    let rest = (title[..<found.lowerBound] + " " + title[title.index(after: end)...])
                        .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                    let source = unquoted(inner)
                    if !source.isEmpty, !rest.isEmpty { return Parts(name: rest, source: source) }
                }
                search = title.startIndex..<found.lowerBound
            }
        }
        return nil
    }

    /// `Shokeen - From "Rabb Da Radio"`.
    private static func dashed(_ title: String) -> Parts? {
        for dash in [" - ", " \u{2013} ", " \u{2014} "] {
            if let range = title.range(of: "\(dash)from ", options: [.caseInsensitive, .backwards]) {
                let name = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let source = unquoted(String(title[range.upperBound...]))
                if !name.isEmpty, !source.isEmpty { return Parts(name: name, source: source) }
            }
        }
        return nil
    }

    /// "From X" on its own, as the second part of a split title.
    private static func fromText(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.lowercased().hasPrefix("from ") else { return nil }
        let source = unquoted(String(t.dropFirst(5)))
        return source.isEmpty ? nil : source
    }

    private static func unquoted(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}")))
    }
}

/// Which songs a search matches: the name, the artist or the stored title, ignoring case and accents.
enum QueueSearch {
    static func matches(_ query: String, in fields: [String?]) -> Bool {
        fields.contains { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
