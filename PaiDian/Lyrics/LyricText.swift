import Foundation

/// Platform word timelines are reduced to their original line start times, never evenly spaced.
enum LyricText {
    static func replacing(_ text:String,_ pattern:String,_ template:String) -> String {
        text.replacingOccurrences(of:pattern,with:template,options:.regularExpression)
    }
    static func timestamp(_ ms:Int64) -> String { String(format:"[%02lld:%02lld.%03lld]",max(0,ms)/60000,(max(0,ms)/1000)%60,max(0,ms)%1000) }
    static func repair(_ text:String) -> String {
        entities(replacing(text,#"\[(\d{2}:\d{2}):(\d{2,3})\]"#,"[$1.$2]"))
    }
    static func entities(_ text:String) -> String {
        var result=text
        for (a,b) in [("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'"),("&apos;","'"),("&nbsp;"," ")] { result=result.replacingOccurrences(of:a,with:b) }
        return result
    }
    static func wordLines(_ raw:String,wordPattern:String) -> String {
        let regex=try! NSRegularExpression(pattern:#"^\[(\d+),\d+\]"#)
        return raw.components(separatedBy:.newlines).compactMap { row -> String? in
            if row.lowercased().hasPrefix("[offset:") { return row }
            if row.hasPrefix("{"),let data=row.data(using:.utf8),let header=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let time=(header["t"] as? NSNumber)?.int64Value,let values=header["c"] as? [[String:Any]] {
                return timestamp(time)+values.compactMap{$0["tx"] as? String}.joined()
            }
            guard let match=regex.firstMatch(in:row,range:NSRange(row.startIndex...,in:row)),let range=Range(match.range(at:1),in:row),let start=Int64(row[range]) else { return row.hasPrefix("[") ? repair(replacing(row,wordPattern,"")) : nil }
            let body=regex.stringByReplacingMatches(in:row,range:NSRange(row.startIndex...,in:row),withTemplate:"")
            return timestamp(start)+entities(replacing(body,wordPattern,""))
        }.joined(separator:"\n")
    }
    static func yrc(_ raw:String) -> String { wordLines(raw,wordPattern:#"\(\d+,\d+,\d+\)"#) }
    static func qrc(_ raw:String) -> String {
        var text=raw
        if let range=text.range(of:"LyricContent=\"") { text=String(text[range.upperBound...]);if let end=text.range(of:"\"/>") { text=String(text[..<end.lowerBound]) } }
        return wordLines(entities(text),wordPattern:#"\(\d+,\d+\)"#)
    }
    static func krc(_ raw:String) -> RawLyrics {
        var translationRows:[String]=[]
        let times=raw.components(separatedBy:.newlines).compactMap { row -> Int64? in
            guard let m=row.range(of:#"^\[\d+,\d+\]"#,options:.regularExpression) else { return nil }
            return Int64(row[m].dropFirst().split(separator:",")[0])
        }
        if let range=raw.range(of:#"\[language:([^\]]+)\]"#,options:.regularExpression) {
            let encoded=String(raw[range].dropFirst(10).dropLast())
            if let data=Data(base64Encoded:encoded),let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let contents=root["content"] as? [[String:Any]],let item=contents.first(where:{($0["type"] as? Int) == 1}),let rows=item["lyricContent"] as? [[String]] {
                for (index,row) in rows.enumerated() where index < times.count { translationRows.append(timestamp(times[index])+row.joined()) }
            }
        }
        let original=wordLines(raw,wordPattern:#"<\d+,\d+,\d+>"#)
        if let offset=raw.range(of:#"(?i)\[offset:[+-]?\d+\]"#,options:.regularExpression) { translationRows.insert(String(raw[offset]),at:0) }
        return RawLyrics(original:original,translation:translationRows.isEmpty ? nil : translationRows.joined(separator:"\n"),format:.krc)
    }
    static func kuwo(_ raw:String) throws -> RawLyrics {
        let regex=try! NSRegularExpression(pattern:#"^\[([\d:.]+)\](.*)$"#)
        var lines:[(time:String,text:String)]=[],translated:[(time:String,text:String)]=[],seen=Set<String>(),tags:[String]=[]
        let isWord=raw.range(of:#"<-?\d+,-?\d+>"#,options:.regularExpression) != nil
        for row in raw.components(separatedBy:.newlines) {
            guard let m=regex.firstMatch(in:row,range:NSRange(row.startIndex...,in:row)),let tr=Range(m.range(at:1),in:row),let lr=Range(m.range(at:2),in:row) else {
                if row.lowercased().hasPrefix("[offset:") { tags.append(row) };continue
            }
            let item=(time:String(row[tr]),text:entities(replacing(String(row[lr]),#"<-?\d+,-?\d+>"#,"")))
            if seen.contains(item.time) {
                guard lines.count >= 2 else { continue }
                var previous=lines.removeLast();previous.time=lines.last!.time;translated.append(previous);lines.append(item)
            } else { lines.append(item);seen.insert(item.time) }
        }
        guard !lines.isEmpty,isWord || !(translated.count > Int(Double(lines.count)*0.3) && lines.count-translated.count > 6) else { throw LyricDecoders.invalid() }
        func text(_ rows:[(time:String,text:String)]) -> String { (tags+rows.map{"[\($0.time)]\($0.text)"}).joined(separator:"\n") }
        return RawLyrics(original:text(lines),translation:translated.isEmpty ? nil : text(translated),format:isWord ? .lyricx : .lrc)
    }
}
