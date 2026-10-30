import Foundation

class PetitLyricsRepository: LyricsRepository {
    private let url = "https://p1.petitlyrics.com/api/GetPetitLyricsData.php"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        
        session = URLSession(configuration: configuration)
    }
    
    private func perform(_ data: [String: Any]) throws -> PetitResponse {
        var finalData = data

        finalData["clientAppId"] = "p1110417"
        finalData["terminalType"] = 10
        
        var request = URLRequest(url: URL(string: url)!)
        
        request.httpMethod = "POST"
        request.httpBody = finalData.queryString.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?
        
        let task = session.dataTask(with: request) { response, _, err in
            error = err
            data = response
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if let error = error {
            throw error
        }
        
        guard let response = try? XMLDecoder().decode(PetitResponse.self, from: data!) else {
            throw LyricsError.decodingError
        }

        return response
    }
    
    //
    
    private func searchSong(_ title: String, artist: String) throws -> PetitSong {
        let response = try perform(
            ["key_title": title, "key_artist": artist, "max_count": 1]
        )
        
        guard let song = response.songs.first else {
            throw LyricsError.noSuchSong
        }
        
        return song
    }
    
    //
    
    private func getSong(_ lyricsId: Int, availableLyricsType: PetitLyricsType) throws -> PetitSong {
        var lyricsType: PetitLyricsType
        
        if availableLyricsType == .linesSynced {
            lyricsType = .plain
        }
        else {
            lyricsType = availableLyricsType
        }
        
        let response = try perform(
            ["key_lyricsId": lyricsId, "lyricsType": lyricsType.rawValue]
        )
        
        guard let song = response.songs.first else {
            throw LyricsError.noSuchSong
        }
        
        return song
    }
    
    //
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        writeDebugLog("[Petit] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let searchResult = try searchSong(query.title, artist: query.primaryArtist)
        let song = try getSong(
            searchResult.lyricsId,
            availableLyricsType: searchResult.availableLyricsType
        )
        
        guard let lyricsData = Data(base64Encoded: song.lyricsData) else {
            throw LyricsError.decodingError
        }
        
        switch song.lyricsType {
            
        case .wordsSynced:
            guard let lyrics = try? XMLDecoder().decode(PetitLyricsData.self, from: lyricsData) 
            else {
                throw LyricsError.decodingError
            }

            if !Self.didDumpRawXml {
                Self.didDumpRawXml = true
                if let xml = String(data: lyricsData, encoding: .utf8) {
                    writeDebugLog("[Petit] raw XML head: \(xml.prefix(1000))")
                }
            }
            
            // Petit 的 starttime/endtime 单位不稳定：行起始时间永远是毫秒（首词 starttime 即绝对 ms），
            // 但词时间在「厘秒格式」下是「相对行首的厘秒差」（存的整数值 = 行首 + 厘秒差，未 ×10）。
            //
            // ★★ 2026-10-30（日志 999 / yanaginagi「終わりの世界から」）：**单位是逐行混用的**。
            //   同一份 XML 里第 1 行每字 80（毫秒，80ms/字），第 2 行起每字 15 / 5（厘秒，
            //   150ms / 50ms/字）。旧代码拿**整首**所有词间隔的中位数（5）判成"厘秒"，
            //   于是第 1 行被 ×10 拉成 11.3 秒，压过第 2 行的 7.88 秒 ⇒ 两行同时亮、
            //   逐词前沿也整体错位。单位必须**按行**判，行首始终按毫秒。
            let timedLines = lyrics.lines.filter { line in
                if !line.linestring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                // `linestring` 空、但词元素里真有字（异常形态）⇒ 保留，别误删一句。
                return line.words.contains { word in
                    !(word.wordstring ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            // ★★ 2026-10-30：把"压在前一行尾巴上的短句"并回前一行。
            //
            // yanaginagi「終わりの世界から」里第 2 行「よ」被单独成行、起点写成 8120ms，
            // 而第 1 行按厘秒换算要到 10280ms 才唱完 ⇒ 两行同时亮。这种"≤3 字、≤2 词、
            // 且起点落在前一行内部超过 0.5s"的行几乎都是上传者拆句/起点填错，
            // 并回前一行后逐词时间轴正好接上（前一行末尾 = 短句起点），也不会再有两行同亮。
            let mergedLines = Self.mergeShortOverlaps(timedLines)
            let mergedCount = timedLines.count - mergedLines.count
            if mergedCount > 0 {
                writeDebugLog("[Petit] merged \(mergedCount) short overlapping line(s) into the previous line")
            }
            let centiLineCount = mergedLines.filter { Self.isCentiseconds($0) }.count
            if centiLineCount > 0 {
                writeDebugLog(
                    "[Petit] time unit: \(centiLineCount)/\(mergedLines.count) line(s) use centiseconds"
                        + " (decided per line; line starts stay in milliseconds)"
                )
            } else {
                writeDebugLog("[Petit] time unit: milliseconds (all \(mergedLines.count) line(s))")
            }

            // 诊断：首末行时间跨度（行起始 = 毫秒，不乘任何系数）
            if let firstLine = mergedLines.first?.words.first?.starttime,
                let lastLine = mergedLines.last?.words.first?.starttime
            {
                writeDebugLog("[Petit] line span: first=\(firstLine)ms last=\(lastLine)ms (\(lyrics.lines.count) lines)")
            }

            let preserveWords = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
            // ★ 2026-10-22（用户）：「Petit 会返回空白行歌词 ⇒ AM 呼吸灯过后（间奏）
            //   是一行空白而不是下一行歌词」。
            //
            // Petit 的 wordsSynced 里，间奏/段落之间常夹着 `linestring` 为空（或纯空白）的
            // **行**；这些行通常还带一个 word 时间戳 ⇒ `LyricsLineDto.isBlankForDisplay`
            // 认不出它们（它只在"没有词级数据"时才算空白行），DTO 那层的统一筛空行也就漏过去了。
            // 这里在**源头**按 `linestring` 丢掉：间奏交给 AM 那边按"行与行之间的时间间隙"
            // 推出来的三个呼吸点，不交给一行空白。
            let droppedBlankLines = lyrics.lines.count - mergedLines.count - mergedCount
            if droppedBlankLines > 0 {
                writeDebugLog("[Petit] dropped \(droppedBlankLines) blank line(s) (no text)")
            }
            writeDebugLog("[Petit] Words-synced lyrics — \(mergedLines.count) line(s)\(preserveWords ? " (word-by-word preserved)" : "")")
            return LyricsDto(
                lines: mergedLines.map {
                    LyricsLineDto(
                        content: $0.linestring,
                        offsetMs: $0.words.first?.starttime,
                        words: preserveWords ? Self.wordDto(for: $0) : nil
                    )
                },
                timeSynced: true,
                romanization: mergedLines.map { $0.linestring }.canBeRomanized
                    ? .canBeRomanized
                    : .original
            )
            
        case .plain:
            let stringLyrics = String(data: lyricsData, encoding: .utf8)!
            // ★ 2026-10-22：同上 —— 纯文本也先丢掉空白行（原先靠 DTO 那层，但这里顺手
            //   一起做，保证"空白行不进 payload"这条在源头就成立）。
            let lines = stringLyrics.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            writeDebugLog("[Petit] Plain lyrics — \(lines.count) line(s)")
            return LyricsDto(
                lines: lines.map { LyricsLineDto(content: $0) },
                timeSynced: false,
                romanization: lines.canBeRomanized ? .canBeRomanized : .original
            )
            
        default:
            throw LyricsError.decodingError
        }
    }

    private static var didDumpRawXml = false
    private static var didLogDegenerate = false
    private static var didLogTextMismatch = false

    /// 检测**这一行**词级时间轴的单位：部分行是厘秒(1/100s)，部分行是毫秒。
    ///
    /// ★★ 2026-10-30：原来按整首所有词的间隔中位数判，而 Petit 的上传数据**会在同一首里
    /// 逐行混用单位**（yanaginagi「終わりの世界から」第 1 行 80ms/字，第 2 行起 15/5，
    /// 即 150ms / 50ms/字）。整首判成厘秒会把第 1 行拉长 10 倍、压到下一行上。
    ///
    /// 依据仍然只有一条：毫秒解释下中位数 < 50ms 相当于 >20 字/秒，人声不可能 ⇒ 实为厘秒。
    /// 单词行没有间隔可判，按毫秒（行首本身就是绝对毫秒，至少不会错到 10 倍）。
    private static func isCentiseconds(_ line: PetitLyricsLine) -> Bool {
        // 合并过的行：词时间已经是绝对毫秒，不能再按原始单位换算。
        guard !line.isNormalized else { return false }
        let starts = line.words.map { $0.starttime }
        guard starts.count > 1 else { return false }
        var gaps: [Int] = []
        for index in 1..<starts.count {
            let gap = starts[index] - starts[index - 1]
            if gap > 0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return false }
        let sorted = gaps.sorted()
        return sorted[sorted.count / 2] < 50
    }

    /// 把一个词的时间换算成绝对毫秒（按它所在行的单位）。
    private static func absoluteWord(
        _ word: PetitLyricsWord,
        in line: PetitLyricsLine
    ) -> PetitLyricsWord {
        let base = line.words.first?.starttime ?? 0
        let centi = isCentiseconds(line)
        func convert(_ raw: Int) -> Int {
            centi ? base + (raw - base) * 10 : raw
        }
        return PetitLyricsWord(
            starttime: convert(word.starttime),
            endtime: word.endtime.map { convert($0) },
            chanum: word.chanum,
            wordstring: word.wordstring
        )
    }

    /// 这一行按自己的单位换算后，最后一个词结束的绝对毫秒。
    private static func lineEndMs(_ line: PetitLyricsLine) -> Int {
        guard let first = line.words.first else { return 0 }
        guard let last = line.words.last else { return first.starttime }
        let base = first.starttime
        let raw = last.endtime ?? last.starttime
        return isCentiseconds(line) ? base + (raw - base) * 10 : raw
    }

    /// 把"压在前一行尾巴上的短句"并回前一行（判据见调用点）。
    ///
    /// 只处理 **≤3 字 / ≤2 词 / 起点落在前一行内部超过 0.5s** 的行 —— 这是上传者拆句
    /// 或把行首填成上一句开头的典型形态。并入时把短句的每个词平移到前一行末尾，
    /// 逐词时间轴正好接上，`linestring` 也拼成完整的一句。
    private static func mergeShortOverlaps(_ lines: [PetitLyricsLine]) -> [PetitLyricsLine] {
        var result: [PetitLyricsLine] = []
        for line in lines {
            guard let previous = result.last else {
                result.append(line)
                continue
            }
            let previousEnd = lineEndMs(previous)
            guard let lineStart = line.words.first?.starttime,
                  lineStart < previousEnd,
                  previousEnd - lineStart > 500 else {
                result.append(line)
                continue
            }
            let text = line.linestring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 3, line.words.count <= 2 else {
                result.append(line)
                continue
            }

            let shift = previousEnd - lineStart
            var merged = previous
            merged.isNormalized = true
            merged.linestring += line.linestring
            // 先把两边都换成绝对毫秒，再平移短句 —— 合并后的行只保留一套单位。
            merged.words = previous.words.map { absoluteWord($0, in: previous) }
                + line.words.map { absoluteWord($0, in: line) }.map { word in
                    var copy = word
                    copy.starttime += shift
                    if let end = copy.endtime { copy.endtime = end + shift }
                    return copy
                }
            result[result.count - 1] = merged
        }
        return result
    }

    /// Petit 的 wordsSynced 词元素带 `wordstring`（词文本，含空格 token）+ starttime + endtime。
    ///
    /// ★★ 2026-10-30（用户：「歌词某行缺字」）：渲染层的逐词文本是**用 syllables 拼出来的**
    /// （`TimedLyricTextBuilder` 的 `characters.map(\.text).joined()`），不是用 `line.content`。
    /// 所以只要词文本拼起来与 `linestring` 差一个字符，屏幕上就会**真的少一个字**
    /// （不是高亮没跟上）。这里立一条硬约束：拼出来的文本必须与 `linestring` 逐字相同；
    /// 不同就返回 nil，让这一行走行级同步、由 `content` 完整显示。
    private static func wordDto(for line: PetitLyricsLine) -> [LyricsWordDto]? {
        let words = line.words
        guard !words.isEmpty else { return nil }

        // 行起始 = 首词 starttime（毫秒，绝对时间）
        let lineOffsetMs = words[0].starttime

        // 退化检测：多词行里所有词 starttime 相同 = 该行无逐字时间轴（Petit 对某些歌返回伪 wordsSynced）。
        // 单词行（words.count == 1）不能判退化：allSatisfy 对单元素数组恒为真，会误丢单词行的时间轴。
        if words.count > 1 && words.allSatisfy({ $0.starttime == lineOffsetMs }) {
            if !Self.didLogDegenerate {
                Self.didLogDegenerate = true
                writeDebugLog("[Petit] degenerate wordsSynced (all words same starttime \(lineOffsetMs)) — fall back to line-level")
            }
            return nil
        }

        // 厘秒格式：词时间是「相对行首的厘秒差」（整数值 = 行首 + 厘秒差，未 ×10），换算成绝对毫秒；
        // 毫秒格式：词时间本身就是绝对毫秒。
        let centi = Self.isCentiseconds(line)
        func convert(_ raw: Int) -> Int {
            centi ? lineOffsetMs + (raw - lineOffsetMs) * 10 : raw
        }

        func makeWord(_ text: String, _ word: PetitLyricsWord) -> LyricsWordDto {
            LyricsWordDto(
                text: text,
                startMs: convert(word.starttime),
                endMs: word.endtime.map { convert($0) }
            )
        }

        // ① 首选：wordstring 齐全且拼起来与 linestring **逐字相同**。
        if words.allSatisfy({ $0.wordstring != nil }) {
            let texts = words.map { word -> String in
                let raw = word.wordstring ?? ""
                // 空格 token 的 wordstring 是纯空白（可能被解码器 trim 成空串），恢复为空格，
                // 否则英文词与词会挤在一起
                return raw.isEmpty ? " " : raw
            }
            if texts.joined() == line.linestring {
                return zip(texts, words).map { makeWord($0, $1) }
            }
        }

        // ② 兜底：按 `linestring` 的**字符**逐个对齐（含空格与标点）。
        //
        // 只在字符数正好等于词数时用 —— 这样拼出来的文本与 linestring 必然逐字相同，
        // 不会缺字；词边界与上传者的分词不同时，只是把时间按字数均分，仍比整行强。
        let characters = Array(line.linestring)
        if characters.count == words.count {
            return zip(characters, words).map { makeWord(String($0), $1) }
        }

        if !Self.didLogTextMismatch {
            Self.didLogTextMismatch = true
            writeDebugLog(
                "[Petit] word text does not match the line — chars \(characters.count) vs words \(words.count)"
                    + ", line-level only: \"\(line.linestring.prefix(60))\""
            )
        }
        return nil
    }
}
