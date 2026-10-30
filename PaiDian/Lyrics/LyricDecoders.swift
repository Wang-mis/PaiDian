import Foundation
import zlib

/// Bounded platform lyric decoders; malformed data never reaches the UI as executable content.
enum LyricDecoders {
    static func invalid() -> AppFailure { .make("歌词格式无效或解码失败",code:"invalidLyrics",module:"lyrics") }
    static func inflate(_ data:Data,allowIncomplete:Bool = false) throws -> Data {
        guard !data.isEmpty,data.count <= 1_048_576 else { throw invalid() }
        var stream=z_stream();guard inflateInit_(&stream,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid() }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { raw in
            stream.next_in=UnsafeMutablePointer(mutating:raw.bindMemory(to:Bytef.self).baseAddress);stream.avail_in=uInt(data.count)
            var result=Data(),buffer=[UInt8](repeating:0,count:4096)
            while true {
                let status=buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out=output.bindMemory(to:Bytef.self).baseAddress;stream.avail_out=uInt(output.count)
                    return zlib.inflate(&stream,Z_SYNC_FLUSH)
                }
                let count=buffer.count-Int(stream.avail_out)
                guard result.count+count <= 1_048_576 else { throw invalid() }
                result.append(contentsOf:buffer.prefix(count))
                if status == Z_STREAM_END { return result }
                if allowIncomplete,stream.avail_in == 0,!result.isEmpty,status == Z_OK || status == Z_BUF_ERROR { return result }
                guard status == Z_OK,count > 0 else { throw invalid() }
            }
        }
    }
    static func krc(_ base64:String) throws -> String {
        guard var data=Data(base64Encoded:base64),data.starts(with:Data("krc1".utf8)) else { throw invalid() }
        data.removeFirst(4)
        let key:[UInt8]=[0x40,0x47,0x61,0x77,0x5e,0x32,0x74,0x47,0x51,0x36,0x31,0x2d,0xce,0xd2,0x6e,0x69]
        return try utf8(inflate(Data(data.enumerated().map{$0.element ^ key[$0.offset % key.count]})))
    }
    static func kuwo(_ data:Data,lyricx:Bool) throws -> String {
        guard data.count >= 10,String(decoding:data.prefix(10),as:UTF8.self).lowercased() == "tp=content",let split=data.range(of:Data([13,10,13,10])) else { throw invalid() }
        let decompressed=try inflate(Data(data[split.upperBound...]))
        if !lyricx { return try utf8(decompressed) }
        let encoded=try utf8(decompressed).trimmingCharacters(in:.whitespacesAndNewlines)
        guard let bytes=Data(base64Encoded:encoded) else { throw invalid() }
        let key=Array("yeelion".utf8)
        return try utf8(Data(bytes.enumerated().map{$0.element ^ key[$0.offset % key.count]}))
    }
    static func qrc(_ hex:String) throws -> String {
        guard !hex.isEmpty,hex.count <= 2_097_152,hex.count % 2 == 0 else { throw invalid() }
        var data=Data();var i=hex.startIndex
        while i < hex.endIndex { let end=hex.index(i,offsetBy:2);guard let byte=UInt8(hex[i..<end],radix:16) else { throw invalid() };data.append(byte);i=end }
        return try utf8(inflate(QRCAlgorithm.transform(data),allowIncomplete:true))
    }
    static func mrc(_ text:String) throws -> String {
        if text.count < 32 { return text }
        guard text.count <= 2_097_152,text.count % 16 == 0 else { throw invalid() }
        var values:[Int64]=[];var i=text.startIndex
        while i < text.endIndex { let end=text.index(i,offsetBy:16);guard let value=UInt64(text[i..<end],radix:16) else { throw invalid() };values.append(Int64(bitPattern:value));i=end }
        let keys:[Int64]=[27303562373562475,18014862372307051,22799692160172081,34058940340699235]
        let delta:Int64=2654435769,n=values.count
        var sum=Int64(6+52/n) &* delta,y=values[0]
        func mix(_ y:Int64,_ z:Int64,_ sum:Int64,_ key:Int64) -> Int64 {
            ((y ^ sum) &+ (z ^ key)) ^ (((z >> 5) ^ (y &<< 2)) &+ ((y >> 3) ^ (z &<< 4)))
        }
        while sum != 0 {
            let e=Int((sum >> 2) & 3)
            for p in stride(from:n-1,through:1,by:-1) { y=values[p] &- mix(y,values[p-1],sum,keys[(p & 3) ^ e]);values[p]=y }
            y=values[0] &- mix(y,values[n-1],sum,keys[e]);values[0]=y;sum=sum &- delta
        }
        var bytes=Data()
        for value in values { var little=value.littleEndian;withUnsafeBytes(of:&little) { bytes.append(contentsOf:$0) } }
        guard let decoded=String(data:bytes,encoding:.utf16LittleEndian) else { throw invalid() }
        return decoded.trimmingCharacters(in:CharacterSet(charactersIn:"\0"))
    }
    private static func utf8(_ data:Data) throws -> String { guard let text=String(data:data,encoding:.utf8) else { throw invalid() };return text }
}
