import Foundation

/// `ImportedLyricsParser` 的断言程序（纯逻辑，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么单钉这一份：解析器是盲写的正则 + 索引，本机没有 Swift 工具链 —— 时间戳算错、
/// 词级切错、译文挂错行都只会表现为"导入之后歌词不对齐"，而不是编译错。这里用可算的
/// 小样本把时间轴、词级切分、译文配对、偏移与编码全部钉住。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

// MARK: - 扩展名识别

require(ImportedLyricsParser.detect(fileExtension: "LRC") == .lrc, "extension matching is case-insensitive")
require(ImportedLyricsParser.detect(fileExtension: " spl ") == .spl, "extension matching trims whitespace")
require(ImportedLyricsParser.detect(fileExtension: "yrc") == .yrc, "yrc is recognized")
for unsupported in ["srt", "ass", "qrc", "krc", "ttml", "lys", "lyl", "spl2"] {
    require(
        ImportedLyricsParser.detect(fileExtension: unsupported) == nil,
        "\(unsupported) is not accepted by the importer"
    )
}

// MARK: - LRC：元信息与偏移

let basicLrc = """
[ti:测试歌]
[ar:歌手]
[length:03:12]
[offset:+500]
[00:01.00]第一句
[00:03.50]第二句
"""
let basic = ImportedLyricsParser.parse(text: basicLrc, format: .lrc)
require(basic.metadata.title == "测试歌", "title survives the metadata pass")
require(basic.metadata.artist == "歌手", "artist survives the metadata pass")
require(basic.metadata.lengthMs == 192_000, "length is converted to milliseconds")
require(basic.metadata.offsetMs == 500, "offset is read as a signed number")
require(basic.lines.count == 2, "two timed lines are parsed")
require(basic.lines.first?.startMs == 500, "a positive offset moves the line earlier")
require(basic.lines.first?.text == "第一句", "line text is kept")
require(basic.lines.first?.words == nil, "plain LRC stays line-level")

// MARK: - 增强型 LRC：词级标记

let enhanced = """
[00:10.00]<00:10.00>你<00:11.00>好<00:12.00>
"""
let enhancedParsed = ImportedLyricsParser.parse(text: enhanced, format: .lrc)
let enhancedLine = enhancedParsed.lines.first
require(enhancedLine?.text == "你好", "word markers are stripped from the line text")
require(enhancedLine?.endMs == 12_000, "the trailing marker becomes the line end")
require(enhancedLine?.words?.count == 2, "two word markers produce two words")
require(enhancedLine?.words?.first?.startMs == 10_000, "the first word starts at the line start")
require(enhancedLine?.words?.last?.endMs == 12_000, "the last word ends at the line end")

// MARK: - SPL：行内标记、显式行结尾、译文

let spl = """
[00:20.00]你好[00:23.00]椒盐音乐[00:24.00]
[00:30.00]Hello
世界
[00:40.00]重复行
[00:40.00]Repeat line
[00:50.00][01:00.00]副歌
[awlrc:lrc:SGVsbG8=]
"""
let splParsed = ImportedLyricsParser.parse(text: spl, format: .spl)
require(splParsed.lines.count == 5, "every timed line is kept (repeat shorthand expands)")
let firstSpl = splParsed.lines.first
require(firstSpl?.words?.count == 2, "inline SPL markers produce two words")
require(firstSpl?.words?.first?.endMs == 23_000, "a word ends where the next marker starts")
require(firstSpl?.endMs == 24_000, "an explicit trailing marker sets the line end")
require(splParsed.lines[1].translation == "世界", "an untimed line becomes the previous line's translation")
require(splParsed.lines[2].translation == "Repeat line", "a same-timestamp line becomes a translation")
require(splParsed.lines[3].text == "副歌" && splParsed.lines[4].text == "副歌",
        "the repeat shorthand yields one line per timestamp")
require(splParsed.lines[3].startMs == 50_000 && splParsed.lines[4].startMs == 60_000,
        "the repeat shorthand uses each timestamp")

// MARK: - 显式结束标记行

let endMarker = """
[01:00.00]一句
[01:02.00]
[01:02.00]下一句
"""
let endMarkerParsed = ImportedLyricsParser.parse(text: endMarker, format: .spl)
require(endMarkerParsed.lines.count == 2, "a marker-only line does not create a lyric line")
require(endMarkerParsed.lines[0].endMs == 62_000, "a marker-only line closes the previous line")

// MARK: - YRC

let yrc = """
[1000,500](1000,100,0)你(1100,200,0)好
[2000,300](2000,300,0)World
"""
let yrcParsed = ImportedLyricsParser.parse(text: yrc, format: .yrc)
require(yrcParsed.lines.count == 2, "yrc lines are parsed")
require(yrcParsed.lines[0].startMs == 1000, "yrc keeps absolute line times")
require(yrcParsed.lines[0].endMs == 1500, "yrc adds the line duration to its start")
require(yrcParsed.lines[0].text == "你好", "yrc word text is joined")
require(yrcParsed.lines[0].words?.count == 2, "yrc keeps word timings")
require(yrcParsed.lines[0].words?.last?.endMs == 1300, "yrc word end is start plus duration")
require(yrcParsed.lines[1].words == nil, "a single-word yrc line degrades to line level")

// MARK: - 编码

let gbkBytes = Data([0xC4, 0xE3, 0xBA, 0xC3]) // “你好” in GB18030
require(ImportedLyricsDecoder.decode(gbkBytes) == "你好", "GB18030 bytes decode instead of turning into mojibake")
let utf8Bytes = "你好".data(using: .utf8)!
require(ImportedLyricsDecoder.decode(utf8Bytes) == "你好", "UTF-8 bytes still decode as UTF-8")
let bomBytes = Data([0xFF, 0xFE]) + "hi".data(using: .utf16LittleEndian)!
require(ImportedLyricsDecoder.decode(bomBytes) == "hi", "a UTF-16 BOM is honoured")

// MARK: - 结果

if failures > 0 {
    print("ImportedLyrics tests: \(failures) failure(s)")
    exit(1)
}
print("ImportedLyrics tests: all passed")
