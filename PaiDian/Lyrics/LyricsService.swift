import Foundation

struct LRCParser: LyricsParsing {
    func parse(_ raw: RawLyrics) throws -> LyricDocument {
        guard (raw.original?.utf8.count ?? 0) <= 1_048_576, (raw.translation?.utf8.count ?? 0) <= 1_048_576 else { throw AppFailure.make("歌词内容过大", code: "invalidLyrics", module: "lyrics") }
        let original = parseText(LyricText.repair(raw.original ?? ""))
        var translation=LyricText.repair(raw.translation ?? "")
        if translation.range(of:#"(?i)\[offset:[+-]?\d+\]"#,options:.regularExpression) == nil,let range=(raw.original ?? "").range(of:#"(?i)\[offset:[+-]?\d+\]"#,options:.regularExpression),let original=raw.original { translation=String(original[range])+"\n"+translation }
        let translated = parseText(translation).lines
        return LyricDocument(timedLines: original.lines.keys.sorted().map { time in LyricLine(startMS: time, text: original.lines[time]!.joined(separator: "\n"), translation: (translated[time] ?? translated.keys.filter{abs($0-time) < 100}.min(by:{abs($0-time)<abs($1-time)}).flatMap{translated[$0]})?.joined(separator: "\n")) }, plainText: original.lines.isEmpty ? original.plain : nil)
    }
    private func parseText(_ text: String) -> (lines: [Int64: [String]], plain: String?) {
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):([0-5]\d)(?:\.(\d{1,3}))?\]"#)
        let offsetRE = try! NSRegularExpression(pattern: #"(?i)\[offset:([+-]?\d+)\]"#)
        let range = NSRange(text.startIndex..., in: text)
        let offset = offsetRE.matches(in: text, range: range).last.flatMap { Range($0.range(at: 1), in: text) }.flatMap { Int64(text[$0]) } ?? 0
        var lines: [Int64: [String]] = [:]; var plain: [String] = []
        for row in text.components(separatedBy: .newlines) {
            let matches = regex.matches(in: row, range: NSRange(row.startIndex..., in: row))
            if matches.isEmpty {
                let clean = row.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && !clean.hasPrefix("[") { plain.append(clean) }; continue
            }
            let content = regex.stringByReplacingMatches(in: row, range: NSRange(row.startIndex..., in: row), withTemplate: "").trimmingCharacters(in: .whitespaces)
            for match in matches {
                func group(_ n: Int) -> String { Range(match.range(at: n), in: row).map { String(row[$0]) } ?? "" }
                guard let minutes = Int64(group(1)), let seconds = Int64(group(2)), minutes < 1_000_000 else { continue }
                let fraction = group(3); let ms = Int64((fraction + "000").prefix(3)) ?? 0
                let time = max(0, minutes * 60_000 + seconds * 1000 + ms - offset)
                if !content.isEmpty && !(lines[time] ?? []).contains(content) { lines[time, default: []].append(content) }
            }
        }
        return (lines, plain.isEmpty ? nil : plain.joined(separator: "\n"))
    }
    func lineIndex(in document: LyricDocument, positionMS: Int64) -> Int? {
        var low = 0, high = document.timedLines.count
        while low < high { let mid = (low + high) / 2; if document.timedLines[mid].startMS <= positionMS { low = mid + 1 } else { high = mid } }
        return low == 0 ? nil : low - 1
    }
}
actor LyricsService: LyricsServing {
    private let providers: [MusicPlatform: any CatalogProvider]; private let cache: any ResourceCache; private let parser: any LyricsParsing
    init(providers: [MusicPlatform: any CatalogProvider], cache: any ResourceCache, parser: any LyricsParsing = LRCParser()) { self.providers = providers; self.cache = cache; self.parser = parser }
    func load(_ track: Track) async throws -> LyricDocument {
        try Task.checkCancellation()
        let key="lrc-v2-m\(track.metadata.schemaVersion)-\(track.key.encoded)",epoch=await cache.epoch()
        if let data=try? await cache.read(key:key,kind:.lyrics),let document=try? JSONDecoder().decode(LyricDocument.self,from:data) { try Task.checkCancellation();return document }
        var plain:LyricDocument?
        func fetch(_ candidate:Track) async throws -> LyricDocument {
            try Task.checkCancellation()
            guard let provider=providers[candidate.key.platform] else { throw LyricDecoders.invalid() }
            let raw=try await provider.fetchLyrics(candidate);try Task.checkCancellation()
            var doc=try parser.parse(raw);doc.origin=LyricOrigin(requestedKey:track.key,sourceKey:candidate.key,format:raw.format)
            return doc
        }
        if let original=try? await fetch(track) {
            if !original.timedLines.isEmpty { try Task.checkCancellation();try? await cache.write(JSONEncoder().encode(original),key:key,kind:.lyrics,epoch:epoch);return original }
            plain=original
        }
        try Task.checkCancellation()
        for platform in MusicPlatform.allCases where platform != track.key.platform {
            guard let provider=providers[platform] else { continue }
            guard let page=try? await provider.search(query:track.title+" "+track.artistText,page:1,pageSize:20) else { try Task.checkCancellation();continue }
            let matches=LyricCandidateMatcher.matches(page.tracks,to:track)
            for candidate in matches.prefix(1) {
                try Task.checkCancellation()
                if let doc=try? await fetch(candidate),!doc.timedLines.isEmpty {
                    try Task.checkCancellation();try? await cache.write(JSONEncoder().encode(doc),key:key,kind:.lyrics,epoch:epoch);return doc
                }
            }
        }
        try Task.checkCancellation()
        if let plain,plain.plainText != nil { return plain }
        throw AppFailure.make("未找到匹配的歌词，请稍后重试",code:"lyricsUnavailable",module:"lyrics",retryable:true)
    }
}

/// Same strict time window and normalized identity fields used by AnyListen's online matching.
enum LyricCandidateMatcher {
    static func normalize(_ text:String) -> String { text.lowercased().replacingOccurrences(of:#"[\s'.,，&"、()（）`~<>|/\[\]!！-]"#,with:"",options:.regularExpression) }
    static func singer(_ track:Track) -> String {
        track.artists.flatMap{$0.components(separatedBy:CharacterSet(charactersIn:"、&/,;；"))}.map(normalize).sorted().joined(separator:"、")
    }
    static func matches(_ candidates:[Track],to target:Track) -> [Track] {
        let name=normalize(target.title),artist=singer(target),album=normalize(target.albumTitle)
        return candidates.enumerated().compactMap { index,candidate -> (Track,Int,Int)? in
            let n=normalize(candidate.title),a=singer(candidate)
            guard !name.isEmpty,!n.isEmpty,(n.contains(name) || name.contains(n)),artist.isEmpty || a == artist || (!a.isEmpty && (a.contains(artist) || artist.contains(a))) else { return nil }
            if let t=target.durationMS,let c=candidate.durationMS,t > 0,c > 0,abs(t-c) >= 5000 { return nil }
            let rank=(n == name ? 0 : 4)+(a == artist ? 0 : 2)+(!album.isEmpty && normalize(candidate.albumTitle) == album ? 0 : 1)
            return (candidate,rank,index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }.map{ $0.0 }
    }
}
