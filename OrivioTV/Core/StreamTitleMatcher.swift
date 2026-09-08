import Foundation

/// How confident we are that a source link is the title the viewer actually
/// asked for.
enum StreamTitleVerdict {
    /// The link names this title (and, for a series, this episode).
    case confirmed
    /// The link says nothing that identifies it either way — most addons that
    /// return "Torrentio 1080p" and nothing else land here. Playable, but a
    /// `confirmed` link is a better bet.
    case unknown
    /// The link names a DIFFERENT title, year, season or episode. Auto-play
    /// must not choose one of these on its own.
    case rejected
}

/// Decides whether a stream link is really the requested movie or episode, by
/// reading the release name the addon returned.
///
/// The Auto Link Selector picks a source with no one watching, and stream
/// addons are not careful: a search for one title routinely comes back with a
/// neighbouring episode, the wrong season, a same-name remake from another
/// decade, or an unrelated film that happens to share a word. Ranking by
/// resolution and size can't see any of that — it will happily auto-play S02E04
/// when you asked for S02E05.
///
/// The rule of the road here is that a WRONG answer is much worse than no
/// answer: every check can only reject on POSITIVE evidence of a mismatch.
/// A link whose name carries no episode marker is `unknown`, not `rejected`,
/// and callers keep those as a fallback — so a strict matcher can never leave
/// a title unplayable.
enum StreamTitleMatcher {

    // MARK: - Public

    /// - Parameters:
    ///   - text: everything the addon said about this link — display name,
    ///     detail line and `behaviorHints.filename`, concatenated.
    ///   - title: the meta title being played.
    ///   - year: release year of the meta, when known (movies).
    ///   - season/episode: the requested episode, nil for a movie.
    ///   - ignoring: the add-on's own name, so "Torrentio" in the label isn't
    ///     read as a title the link is claiming to be.
    static func verdict(text: String, title: String, year: Int?,
                        season: Int?, episode: Int?,
                        ignoring: String = "") -> StreamTitleVerdict {
        let haystack = normalize(text)
        guard !haystack.isEmpty else { return .unknown }
        let words = Set(haystack.split(separator: " ").map(String.init))

        // 1. Episode — the check that matters most, and the one release names
        //    are most reliable about.
        var episodeOK: Bool?
        if let season {
            episodeOK = episodeVerdict(haystack: haystack, season: season, episode: episode)
            if episodeOK == false { return .rejected }
        }

        // 2. Title words.
        let titleOK = titleVerdict(words: words, haystack: haystack, title: title, ignoring: ignoring)
        if titleOK == false { return .rejected }

        // 3. Year — movies only. Episode markers already pin a series, and
        //    series release names carry the SHOW's start year, the air year of
        //    the season, or nothing, which makes a year check there a source of
        //    false rejections rather than a safeguard.
        if season == nil, let year {
            if yearVerdict(haystack: haystack, title: title, year: year) == false { return .rejected }
        }

        guard titleOK == true else { return .unknown }
        if season != nil { return episodeOK == true ? .confirmed : .unknown }
        return .confirmed
    }

    /// Everything an addon told us about a link, as one searchable string.
    static func haystack(displayName: String, displayDetail: String, filename: String?) -> String {
        [displayName, displayDetail, filename ?? ""].joined(separator: " ")
    }

    // MARK: - Episode

    /// `true` when the name names THIS episode (or this season, for a pack),
    /// `false` when it names a different one, nil when it names none.
    private static func episodeVerdict(haystack: String, season: Int, episode: Int?) -> Bool? {
        let pairs = episodeMarkers(in: haystack)
        if !pairs.isEmpty {
            // A multi-episode file ("s01e01-e03") lists several pairs; any hit
            // means the file contains what was asked for.
            if let episode {
                if pairs.contains(where: { $0.season == season && $0.episode == episode }) { return true }
                return false
            }
            return pairs.contains { $0.season == season } ? true : false
        }
        // No episode marker: a season pack still identifies itself, and the
        // addon hands back the right file from inside it.
        let seasons = seasonMarkers(in: haystack)
        if !seasons.isEmpty { return seasons.contains(season) }
        return nil
    }

    /// Season/episode pairs written any of the usual ways: `s01e02`, `s1 e2`,
    /// `1x02`, `season 1 episode 2`. The normalizer has already reduced
    /// punctuation to single spaces, so one pattern set covers all the
    /// separators releases use (dots, dashes, underscores, brackets).
    static func episodeMarkers(in haystack: String) -> [(season: Int, episode: Int)] {
        var out: [(season: Int, episode: Int)] = []
        for pattern in [
            #"\bs(\d{1,2})\s?e(\d{1,3})\b"#,
            #"\b(\d{1,2})x(\d{1,3})\b"#,
            #"\bseason\s?(\d{1,2})\s?episode\s?(\d{1,3})\b"#,
        ] {
            for match in matches(pattern, in: haystack) where match.count >= 3 {
                guard let s = Int(match[1]), let e = Int(match[2]) else { continue }
                out.append((s, e))
            }
        }
        // Multi-episode files: "s01e01e02", "s01e01 e02 e03" list them, while
        // "s01e04-e06" means the whole RANGE — episode 5 is in that file even
        // though nothing names it. Both hang off the first marker's season.
        if let first = out.first {
            for match in matches(#"\be(\d{1,3})\b"#, in: haystack) where match.count >= 2 {
                guard let e = Int(match[1]) else { continue }
                if !out.contains(where: { $0.episode == e }) { out.append((first.season, e)) }
            }
            // The range's first episode is glued to its season ("s03e04 e06"
            // once punctuation is folded away), so the pattern has to start at
            // the season marker — `\be(\d+)` never matches mid-token.
            for match in matches(#"\bs\d{1,2}\s?e(\d{1,3})\s?e(\d{1,3})\b"#, in: haystack)
            where match.count >= 3 {
                // Bounded to a plausible span within one season: a run-together
                // LIST ("e01e03") is indistinguishable from a RANGE once the
                // dash is folded, and filling a huge span on a misread would
                // wave through episodes the file doesn't contain.
                guard let from = Int(match[1]), let to = Int(match[2]), from < to, to - from <= 12
                else { continue }
                for e in from...to where !out.contains(where: { $0.episode == e }) {
                    out.append((first.season, e))
                }
            }
        }
        return out
    }

    /// Season-only markers: `s01`, `season 1`, `the complete second season`.
    static func seasonMarkers(in haystack: String) -> [Int] {
        var out: [Int] = []
        for pattern in [#"\bs(\d{1,2})\b"#, #"\bseason\s?(\d{1,2})\b"#] {
            for match in matches(pattern, in: haystack) where match.count >= 2 {
                if let s = Int(match[1]) { out.append(s) }
            }
        }
        return out
    }

    // MARK: - Title

    /// Words too common to carry any signal — matching on them alone would
    /// "confirm" every link in the list.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for", "part",
    ]

    /// Release-name furniture: quality, source, codec, audio, debrid and
    /// scene-group vocabulary. None of it names a TITLE, so a link built only
    /// out of these words ("Torrentio 1080p", "RealDebrid 4K cached") is
    /// telling us nothing rather than naming something else — the difference
    /// between `unknown` and `rejected`.
    private static let releaseJargon: Set<String> = [
        // resolution / source
        "2160p", "1080p", "720p", "480p", "4k", "uhd", "hd", "sd", "web", "webdl", "webrip",
        "bluray", "brrip", "bdrip", "bdremux", "hdtv", "dvdrip", "dvd", "remux", "cam", "ts",
        "telesync", "screener", "hdrip", "hqcam",
        // video / hdr
        "hdr", "hdr10", "sdr", "dv", "dovi", "dolby", "vision", "hybrid", "10bit", "8bit",
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid", "divx", "fps",
        // audio
        "atmos", "truehd", "ddp", "dd", "ac3", "eac3", "aac", "dts", "hdma", "ma", "flac",
        "opus", "ch", "audio", "dual", "multi", "dub", "dubbed", "sub", "subs", "subbed",
        // packaging / edition
        "proper", "repack", "extended", "uncut", "unrated", "remastered", "imax", "limited",
        "directors", "cut", "edition", "theatrical", "complete", "season", "episode", "pack",
        // delivery / trackers / debrid
        "torrentio", "comet", "jackett", "prowlarr", "mediafusion", "cached", "instant",
        "realdebrid", "premiumize", "torbox", "alldebrid", "debrid", "rd", "ad", "pm", "tb",
        "seeders", "peers", "size", "gb", "mb", "gib", "mib", "kbps", "mbps",
        // scene groups seen constantly
        "rarbg", "yts", "yify", "psa", "galaxy", "tgx", "ettv", "eztv", "ntb", "flux",
        "successfulcrab", "playweb", "cmrg", "edith", "megusta", "minx",
    ]

    /// `true` when every meaningful word of the title is present, `false` when
    /// the link plainly names something else, nil when it names nothing at all.
    private static func titleVerdict(words: Set<String>, haystack: String,
                                     title: String, ignoring: String) -> Bool? {
        let wanted = normalize(title)
            .split(separator: " ")
            .map(String.init)
            .filter { !stopwords.contains($0) && $0.count > 1 }
        guard !wanted.isEmpty else { return nil }

        // Releases glue words together ("spiderman", "starwars") as often as
        // they separate them, so a run-together spelling counts as present.
        let squashed = haystack.replacingOccurrences(of: " ", with: "")
        let present = wanted.filter { words.contains($0) || squashed.contains($0) }.count

        if present == wanted.count { return true }
        // A long title survives one missing word (subtitles get dropped, "&"
        // becomes "and", numerals swap for words); a short one does not, since
        // one word out of two is no evidence at all.
        if wanted.count >= 4, present >= wanted.count - 1 { return true }

        // Does this link name ANY title? Strip the release furniture, the
        // add-on's own name and bare numbers, and see whether words are left.
        // "Torrentio 1080p" has nothing left — it isn't claiming to be some
        // other film, it just didn't say. Rejecting those would reject most of
        // a Torrentio list.
        let ignored = Set(normalize(ignoring).split(separator: " ").map(String.init))
        let namesSomething = words.contains { word in
            !releaseJargon.contains(word) && !stopwords.contains(word) && !ignored.contains(word)
                && word.count > 1 && !word.allSatisfy(\.isNumber)
                // "s03e05", "10bit", "5 1" — markers, not title words.
                && matches(#"^(s\d+e?\d*|\d+x\d+|\d+bit|\d+p|\d+ch)$"#, in: word).isEmpty
        }
        guard namesSomething else { return nil }

        // It named something, and it wasn't this. A partial overlap is still
        // ambiguous (a translated title, a differently-punctuated one), so only
        // a total miss rejects.
        return present > 0 ? nil : false
    }

    // MARK: - Year

    /// `false` only when the name carries release years and NONE is the one we
    /// want. ±1 because release names disagree with metadata about festival vs
    /// wide release dates all the time.
    private static func yearVerdict(haystack: String, title: String, year: Int) -> Bool? {
        // A year inside the TITLE itself ("blade runner 2049", "1917") is not a
        // release year — don't let it look like a mismatched one.
        let titleYears = Set(matches(#"\b(\d{4})\b"#, in: normalize(title)).compactMap { Int($0[1]) })
        let found = matches(#"\b(19\d{2}|20\d{2})\b"#, in: haystack)
            .compactMap { Int($0[1]) }
            .filter { !titleYears.contains($0) }
        guard !found.isEmpty else { return nil }
        return found.contains { abs($0 - year) <= 1 }
    }

    // MARK: - Helpers

    /// Lowercased, diacritics folded, every run of non-alphanumerics collapsed
    /// to one space. Release names separate words with dots, underscores,
    /// dashes and brackets interchangeably; this makes them all the same shape.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Parse a year out of a meta's `releaseInfo` ("2019", "2019–", "2019-2023").
    static func year(fromReleaseInfo info: String?) -> Int? {
        guard let info else { return nil }
        return matches(#"\b(19\d{2}|20\d{2})\b"#, in: info).compactMap { Int($0[1]) }.first
    }

    /// Regexes are compiled ONCE and reused: this runs over every entry of a
    /// source list on every auto-link evaluation, and `range(of:.regularExpression)`
    /// recompiles its pattern on each call.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        guard let made = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        regexCache[pattern] = made
        return made
    }

    /// All matches of `pattern`, each as its capture groups (index 0 = whole).
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = regex(pattern), !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).map { match in
            (0..<match.numberOfRanges).map { i in
                Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
