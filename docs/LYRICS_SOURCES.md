# 歌词从哪来、怎么逆向

> 这份文档回答两件事：**我们的歌词是从哪个接口来的**，以及**要加一个新源时该去哪儿找成熟的实现**。
> 2026-10-31 整理，配合「自动优选」（`LyricsAutoSelect.swift`）一起看。
>
> ⚠️ 本文只记录**接口形态与逆向思路**，不包含任何歌词内容，也不含任何账号凭据。
> 各平台的条款对"第三方客户端取词"态度不一，接入前先看第 5 节。

---

## 0. 一句话结论

- 本仓库现在有 **12 个源**（Genius / LRCLIB / Musixmatch / PetitLyrics / Spicy Lyrics / NetEase /
  AMLL / BiniLyrics / Unison / QQ 音乐 / 酷狗 / Apple Music 官方 TTML）。
  2026-10-31 这一轮把 Taurus 有、我们缺的四个（BiniLyrics / Unison / QQ / 酷狗）补齐了。
- 覆盖面已经不是瓶颈，**调度**才是 —— 所以同一轮也把「多级回退」换成了「自动优选」
  （见 `LyricsAutoSelect.swift` 与第 4 节）。
- 还没接的只剩一个：**用户自己导入的 .lrc 文件**（Taurus 的 `Imported LRC`）——
  那是文件选择器 + 存储，不是取词接口。
- **只有 KRC 与 QRC 是加密的**；YRC 是**明文**（加密的只是网易云 eapi 的**请求**），
  当初能直接解析就是因为它没加密。
- 逆向这件事，**不要从抓包开始**。GitHub 上已经有把签名、加密、匹配全部做完的项目，
  先读它们，再决定要不要自己抓 —— 抓包只在"接口变了、开源实现还没跟上"时才必要。

---

## 1. 本仓库已接入的源（现状）

| 源 | 入口 | 鉴权 | 时间轴 | 备注 |
|---|---|---|---|---|
| Genius | `api.genius.com` + 网页抓取 | 内置 client token | 无（纯文本） | 兜底用，永远最后问 |
| LRCLIB | `lrclib.net/api`（地址可改） | 无 | 行级 | 开放、稳定、覆盖一般 |
| Musixmatch | 官方 web/desktop API | 用户 `usertoken`，没有则匿名换一个 | 行级 + richsync 逐字 | 商用曲库，逐字覆盖不高 |
| PetitLyrics | `p1.petitlyrics.com/api/GetPetitLyricsData.php` | 无 | 行级 + 逐字 | 日文曲库最强 |
| Spicy Lyrics | `api.spicylyrics.org` | **用户自己的 client key**（`sl_pk_…`） | 逐字（syllable） | 条款要求署名 provider + 贡献者 |
| NetEase | `music.163.com` weapi / `interface3.music.163.com` eapi | 无（匿名 cookie + csrf） | 行级 + **yrc 逐字** | 中文曲库最强；yrc 只走 eapi |
| AMLL | `api.amll.dev/v1/lyrics/get?spotifyId=` | 无 | 逐字（TTML） | 唯一接受 Spotify Track ID 的 TTML 库 |
| BiniLyrics | `lyrics-api.binimum.org/?track=&artist=&duration=&album=` | 无 | 逐字（TTML） | 社区收的 Apple Music TTML，**按名字搜** |
| Unison | `unison.boidu.dev/lyrics?song=&artist=&duration=&album=` | 无 | 逐字（TTML） | 人工打轴，曲库小 |
| QQ 音乐 | `u.y.qq.com/cgi-bin/musicu.fcg`（两次 POST） | 无（但要 `Referer: https://y.qq.com/`） | 逐字（QRC）+ 行级（LRC） | 中文曲库；QRC = hex + 3DES + zlib |
| 酷狗 | `krcs.kugou.com/search` → `lyrics.kugou.com/download` | 无 | 逐字（KRC） | 中文曲库；KRC 要解包 |
| Apple Music 官方 TTML | `amp-api.music.apple.com/v1/catalog/{sf}/songs/{id}?include[songs]=syllable-lyrics` | 用户 `media-user-token` + 自动抓的 developer token | 逐字（TTML） | 实验开关，开了就覆盖其它全部设置 |

### 三条容易踩的细节

1. **网易云的 yrc 只有 eapi 给。** 老的 `POST /weapi/song/lyric` 只下行级 `lrc`；
   逐字要走 `POST https://interface3.music.163.com/eapi/song/lyric/v1`，body 用
   `eapi` 那套 AES-128-ECB（key 固定 `e82ckenh8dichen8`，无 IV）加密。
   见 `NeteaseLyricsRepository.fetchYrcRaw`。
2. **Petit 的逐字单位逐行混用。** 同一首里有的行按毫秒、有的行按厘秒存
   （厘秒存的是"行首 + 厘秒差"）。按整首中位数判会毁掉第一行，必须**逐行**判。
   见 `PetitLyricsRepository.isCentiseconds(_:)`。
3. **AMLL 的 TTML 有两种形态**：有 `<span>` 的是逐字，只有 `<p begin>` 的是行级。
   「AMLL 优先」只接受前者，判据必须与渲染层共用 `hasUsableWordLevelData`。

---

## 2. GitHub 上的成熟项目

按"能不能直接照着实现"排序。**许可那一列是接入前必须核对的**。

| 项目 | 语言 | 许可 | 覆盖 | 值得抄什么 |
|---|---|---|---|---|
| [WXRIW/Lyricify-Lyrics-Helper](https://github.com/WXRIW/Lyricify-Lyrics-Helper) | C# | Apache-2.0 | QQ / 网易 / 酷狗 / 汽水 / Apple Music / Musixmatch / Spotify / LRCLIB | **目前最完整的一份**。搜索打分、QRC/KRC/YRC 解密、TTML 解析、格式互转全都有；`docs/providers.md` 写清了每个源要什么凭据 |
| [lihato/LDDC](https://github.com/lihato/LDDC) | Python | 见仓库 LICENSE | QQ / 酷狗 / 网易 / LRCLIB | 逐字歌词的**匹配**做得比取词还细；多线程批量匹配、KRC 解密调用链 |
| [Robotxm/ESLyric-LyricsSource](https://github.com/Robotxm/ESLyric-LyricsSource) | JavaScript | 见仓库 | QQ(QRC) / 酷狗(KRC) / 网易(YRC) | 纯 JS 的 QRC 解密重实现，适合对照着读算法 |
| [Binaryify/NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi) | JavaScript | MIT | 网易云全量 | weapi/eapi 加密的**参考实现**（`util/crypto.js`）；本仓库的网易云就是照它写的 |
| [jitwxs/163MusicLyrics](https://github.com/jitwxs/163MusicLyrics) | C# | Apache-2.0 | 网易 / QQ | 批量取词与文件名匹配策略 |
| [zhaarey/apple-music-downloader](https://github.com/zhaarey/apple-music-downloader) | Go | 见仓库 | Apple Music | 从 `music.apple.com` 的 JS 里正则抠 developer token（`internal/amp-api/token.go`） |
| [dropcreations/Manzana-Apple-Music-Lyrics](https://github.com/dropcreations/Manzana-Apple-Music-Lyrics) | Python | 见仓库 | Apple Music | songs / lyrics 端点与 TTML 结构 |
| [amll-dev/applemusic-like-lyrics](https://github.com/amll-dev/applemusic-like-lyrics) + [amll-ttml-db](https://github.com/amll-dev/amll-ttml-db) | TypeScript | 见仓库 | TTML | TTML 的字段语义（`ttm:role`、背景人声、对唱） |
| [SideloadLabs/EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) | Swift | 见仓库 | Spicy Lyrics | 本仓库 Spicy 源的来源 |
| [cXp1r/Lyrix](https://github.com/cXp1r/Lyrix) | Rust | 见仓库 | 多源 | 高性能 LRC/QRC/KRC 解析（`memchr`），做本地缓存时值得看 |

> **Taurus（`C:\dsh\ipa\Taurus-0.60.5.ipa`）是 PolyForm Strict 1.0.0**：
> 只能读思路，不能抄代码。本仓库的「自动优选」抄的是它的**调度规则**（见第 4 节），
> 一行 Objective-C 都没搬。

---

## 3. 各平台接口与逆向要点

### 3.1 网易云（已接入）

```
搜索   POST https://music.163.com/weapi/cloudsearch/get/web        (weapi)
行级   POST https://music.163.com/weapi/song/lyric?csrf_token=     (weapi, lv=-1)
逐字   POST https://interface3.music.163.com/eapi/song/lyric/v1    (eapi, yv=0)
```

- `weapi`：`params = AES-CBC(AES-CBC(json, "0CoJUm6Qyw8W8jud"), randomKey)`，
  `encSecKey = RSA(randomKey)`。固定 nonce / pubkey / modulus 见
  `NeteaseLyricsRepository`。
- `eapi`：`params = AES-128-ECB(urlPath + json + urlPath, "e82ckenh8dichen8")`，无 IV。
- 响应里 `lrc.lyric` / `yrc.lyric` / `tlyric.lyric` / `romalrc.lyric` 各是一套时间轴，
  **yrc 与 tlyric 的行头不是同一套**，逐字译文要配 `ytlrc`。

### 3.2 QQ 音乐（已接入，逐字 QRC + 逐行 LRC）

来自 `Lyricify-Lyrics-Helper/Providers/Web/QQMusic/Api.cs`、`chenmozhijin/LDDC`
（`core/api/lyrics/qm.py` + `core/decryptor/__init__.py`）与 `naiyQAQ/pyqdes`（`main.cpp`）：

```
搜索   POST https://u.y.qq.com/cgi-bin/musicu.fcg
       {"comm":{…}, "req":{"module":"music.search.SearchCgiService",
                           "method":"DoSearchForQQMusicDesktop","param":{…}}}
歌词   POST https://u.y.qq.com/cgi-bin/musicu.fcg
       {"comm":{…}, "music.musichallSong.PlayLyricInfo.GetPlayLyricInfo":{
           "module":"music.musichallSong.PlayLyricInfo","method":"GetPlayLyricInfo",
           "param":{"qrc":1,"crypt":1,"songID":…,"songName":<b64>,"singerName":<b64>,
                    "albumName":<b64>,"interval":<秒>,"lrc_t":0,"qrc_t":0,
                    "trans":0,"roma":0,"type":0}}}
旧接口 POST https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg
       version=15&miniversion=82&lrctype=4&musicid=<songmid>
```

- `data["qrc_t"] != 0` ⇒ `data["lyric"]` 是**加密的 QRC**；等于 0 才是 base64 的明文 LRC。
- **QRC 解密三步**（LDDC 与 pyqdes 两个独立项目交叉验证，字节序完全一致）：
  1. **hex** 解码（不是 base64；也见过 base64 形态，代码里两种都试）；
  2. **3DES 解密**，ECB、无填充，密钥 `!@#)(*$%123ZXC!@!@#)(NHL`（24 字节 = k1|k2|k3），
     等价于 `DES-dec(k1) → DES-enc(k2) → DES-dec(k3)`；
  3. **zlib 解压**。
- ⚠️ 网上流传的"128 字节 gamma 表"是**音乐文件**（.mflac / .mgg）那套 QMC 加密，与歌词 QRC 无关。
  歌词这边就是标准 3DES + zlib —— 本文档早先写错过这一点，2026-10-31 更正。
- 正文可能裹在 `<Lyric_1 LyricType="1" LyricContent="…"/>` 里：取属性值，并还原 XML 实体。
- **逐字格式**：`[行首,行时长]词(起始,时长)词(起始,时长)…` —— 时间戳写在**文字后面**，
  与 yrc / KRC 相反；字偏移一般是整首绝对时间（代码里逐行探测，兼容相对写法）。
- **没有任何鉴权**，但 `Referer: https://y.qq.com/` 必须带。

本仓库的实现在 `QQMusicLyricsRepository` + `QrcText`，所以它在自动优选里是 **word 档**
（`canProduceWordTiming == true`）；`qrc_t == 0` 或解不开时退回明文 LRC，那一首就只是行级。

⚠️ 两个请求的 body 结构容易抄错：第一个用 `"req"` 当键，**第二个用的是完整模块名**
`"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo"`。抄成 `"req"` 的表现是永远拿不到 `data`。

### 3.3 酷狗（已接入，逐字）

来自 `Lyricify-Lyrics-Helper/Providers/Web/Kugou/Api.cs` 与 `LDDC/core/api/lyrics/kg.py`：

```
搜索   GET  https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=…&duration=…&hash=…
下载   GET  http://lyrics.kugou.com/download?ver=1&client=mobi&id=<id>&accesskey=<accesskey>&fmt=krc&charset=utf8
```

- 搜索返回的每条带 `id` + `accesskey`，两个都要原样带进下载。
- 下载回来是 base64 的 **KRC**（前 4 字节 `krc1`，之后是 zlib 压缩 + 逐字节异或）。
  `contenttype == 2` 时是纯文本 LRC，不必解密。
- LDDC 那边还带了一套 `mid` / `dfid` / `signature` 的设备注册流程
  （`https://userservice.kugou.com/risk/v1/r_register_dev`，签名 = `md5("1014" + 排序后的值 + "1014")`）。
  **歌词接口本身不需要这套**，只有搜索/歌单接口需要 —— 接歌词时可以跳过。

**本仓库的实现（`KuGouLyricsRepository` + `KrcText`）**：

- 搜索用 `https://krcs.kugou.com/search`（比 Lyricify 用的 `lyrics.kugou.com/search` 少几个参数），
  关键词是 `"<歌手> - <歌名>"`，顺序不能反；
- 解包在 `KrcText`：base64 → `"krc1"` 魔数 → **16 字节 XOR** → zlib 解压 → 逐行解析。
  那个 16 字节密钥是酷狗客户端内置的常量，不随用户/曲目变；
- ⚠️ Apple 的 `COMPRESSION_ZLIB` 吃的是**裸 DEFLATE**，而酷狗给的是**带 zlib 头尾**的流
  （RFC 1950）—— 必须先剥掉 2 字节头与 4 字节 adler32。这一步搞反的表现是"解压永远失败"。
- ⚠️ KRC 的字偏移是**相对本行行首**（yrc 是整首绝对时间）。搞反的表现是
  "第一行准、后面越来越离谱"。

### 3.3b BiniLyrics / Unison（已接入，逐字）

这两个都是"社区收的 Apple Music 逐字 TTML"，都是**一个 GET 拿正文**，但响应形状不同：

```
BiniLyrics  GET https://lyrics-api.binimum.org/?track=<歌名>&artist=<歌手>&duration=<秒>&album=<专辑>
            → {"results": [{"track_name": "…", "artist_name": "…", "lyricsUrl": "...ttml",
                            "duration": 213, "timing_type": "word", "isrc": "…"}]}
            → 再 GET lyricsUrl 拿 TTML 正文

Unison      GET https://unison.boidu.dev/lyrics?song=<歌名>&artist=<歌手>&duration=<秒>&album=<专辑>
            → {"success": true,
               "data": {"format": "ttml", "lyrics": "<TTML 正文>", "syncType": "richsync",
                        "confidence": "high", "song": "…", "artist": "…"}}
            → 没命中：{"success": false, "error": "…", "code": "NOT_FOUND", "hint": "…"}
```

- BiniLyrics 回的是**候选列表**，要自己挑：先过三道闸（曲名去标点后全等 / 歌手互相包含 /
  时长 ±4 秒），再按逐字优先、时长更接近排序。**只按时长挑会配到翻唱** ——
  实测 `Blinding Lights / The Weeknd` 的 20 条结果里有 17 条是别人的版本
  （187s、221s…），原曲 200s，4 秒容差足够放进一两首；
- Unison 回的是**它自己挑好的最高分**，外面套一层 `{success, data}` 信封，没命中时没有 `data`。
  匹配在**服务端**做（公开文档见 `github.com/better-lyrics/unison`）：按 `v` → `isrc` →
  `song + artist` 的顺序找，歌手按完整署名比，给了 `duration` 就按 **±2 秒**收窄。
  所以客户端只验三件事：`success`、`format == "ttml"`、能解析出至少一行。
  ⚠️ **响应里没有 `duration` 字段** —— 早期版本拿它比对，那个分支从来没执行过；
  `confidence` 也是字符串档位（`low` / `medium` / `high`），不是数字；
- 两家都不需要鉴权。BiniLyrics 还有一条"按 ISRC 直取"的捷径
  （`https://lrc.red/s/<isrc>.ttml`），但我们手上没有 ISRC，走不了。

解析**完全复用** `AmllTtmlParser` + `AmllLyricsMapper` —— AMLL 的格式本来就是照 Apple 的做的，
Apple Music 官方那条线也是同一个 mapper。

### 3.4 Apple Music（已接入，实验）

```
token  GET https://music.apple.com/us/browse  → 正则抠 index*.js → 再抠 JWT
歌词   GET https://amp-api.music.apple.com/v1/catalog/{storefront}/songs/{id}
          ?include[songs]=syllable-lyrics&l=zh-hans-cn&extend=ttmlLocalizations
头     Authorization: Bearer <developer token>
       media-user-token: <用户自己的令牌>
       Origin: https://music.apple.com
```

- developer token 是**公开的 web player 令牌**，任何人打开 music.apple.com 都能拿到；
  真正代表"你是谁"的是 `media-user-token`。
- TTML 里的 `ttm:role="x-bg"` 是背景人声、`ttm:role="x-translation"` 是译文、
  `ttm:role="x-roman"` 是罗马音。本仓库已按这三条解析。

### 3.5 Spotify 自家（未接入）

`spclient` 的 `color-lyrics/v2` 就是本仓库**拦截并替换**的那条请求。
要主动去问它，需要 `sp_dc` cookie 换 access token —— 属于"用别人的账号体系"，
不建议接（而且我们本来就在替换它）。

### 3.6 Musixmatch

两条路：Android API（`api.musixmatch.com/ws/1.1/…`，要 `usertoken`）与桌面 API。
`usertoken` 可以匿名申请（本仓库的 `AnonymousTokenHelper`），但**有时效**，
401 之后要重新换。逐字歌词在 `richsync` 字段，覆盖远低于行级 `subtitle`。

### 3.7 LRCLIB

`GET https://lrclib.net/api/get?track_name=&artist_name=&album_name=&duration=`
返回 `syncedLyrics` / `plainLyrics` 两个字段 —— **只有前者有时间轴**。
自动优选里它是"行级"档，所以排在所有能出逐字的源之后。

### 3.8 AMLL

`GET https://api.amll.dev/v1/lyrics/get?spotifyId=<trackID>` → TTML。
404 = 库里没有（静默降级），429/502 = 服务问题（要退避重试，不能当成"没词"）。
唯一的"按 Spotify ID 精确匹配"的 TTML 源，所以它在链路里位置很靠前。

### 3.9 PetitLyrics

`POST https://p1.petitlyrics.com/api/GetPetitLyricsData.php`，
`lyricsType` 决定返回的是行级还是逐字；正文是 base64 的自有格式。

---

## 4. 「自动优选」的规则从哪来

规则是照着 Taurus 的**行为**定的（只读行为，没有引用它的实现）。它那边只有四条：

| # | 规则 | 我们对应的实现 |
|---|---|---|
| 1 | 按用户排好的顺序逐个问 | `LyricsSourceOrder.current` + `LyricsAutoSelect.chain()` |
| 2 | 纯文本不终止查找：有文本 > 没文本，细时间轴 > 粗时间轴 | `LyricsTimingTier`（word > line > untimed），同档先到先得 |
| 3 | 纯音乐是结论，立刻收工 | `CustomLyrics.autoSelectLyrics` 里的 `isInstrumental` 分支 |
| 4 | 拿到"有时间轴的正文"就收工 | 停在**想要的那一档**，见下面的分歧 |

外加三条工程细节，按同样的思路处理（都是策略，不是代码）：

- **名字晚到**：搜索型源在曲目还没被播放器命名时先跳过，等按 ID 匹配的源把名字补上再回头问一次。
  我们的 `LyricsSearchQuery` 在请求入口就从 metadata 拿全了，这条不需要。
- **失败不记成"没有词"**：网络失败 / 429 / 5xx 时**不缓存**"这首没词"的结论，下次重问。
  我们的对应做法是：超时/抛错只记 `firstError`，绝不写成 `noSuchSong`。
- **逐首缓存 + 并发去重**：同一首并发来的请求只跑一次链路。
  我们由 `LyricsResponseCache` 的 payload 备忘承担。

**刻意的分歧**（两条）：

- Taurus 停在"第一个有时间轴的答案"，我们停在"**想要的那一档**"：
  逐字开关打开时会为逐字多等最多 4 秒。理由是两边的预算不同 ——
  Taurus 要在 1 秒内把卡片喂出来，我们的响应预算是 18 秒。
- Taurus 让用户拖动排序来源 —— 这一条我们也做了（2026-10-31 用户提出之后）。
  我们的实现是 `LyricsSourceOrder` + 设置 → 歌词 → 来源顺序，默认顺序由用户指定：
  `amll → sl → pl → 网易云 → qq → 酷狗 → un → mxm → bini → lrclib → gen`。
  与 Taurus 的差别只有一个：它的顺序同时是"开关列表"（不在列表里 = 关掉），
  我们只做排序 —— 想只用某一个源，上一页的单源选择器已经能做到。
**另外**：「自动优选」**只在听歌页样式为沉浸式 / Apple Music 时可选**（2026-10-31 用户）。
Spotify 原生样式下选项被滤掉，盘上存的值不改，切回沉浸式 / AM 式会自动恢复；
那期间按 `LyricsSource.defaultSource` 取词。见 `LyricsSource.isAvailableInCurrentNowPlayingStyle`。

---

## 5. 加新源之前

1. **先看许可**。Lyricify 是 Apache-2.0（可参考、要署名）；Taurus 是 PolyForm Strict（只能读思路）；
   有些仓库根目录的 LICENSE 与 README 写的不一致，以 LICENSE 文件为准。
2. **先看条款**。QQ / 酷狗 / 网易的接口都没有公开授权给第三方客户端；
   Spicy Lyrics 明确要求"每人一份自己的 key、不许共用"（本仓库已按这个做）。
3. **先想清楚匹配**。取词本身是一行 HTTP；真正会翻车的是"这首歌到底是不是这首"。
   时长、歌手、专辑、标题变体四项至少要中两项 —— 见 `LyricsSearchQuery` 与各仓库的打分段。
4. **加完记得进链路**。新源要么进 `LyricsAutoSelect.chain()`，要么进 `canProduceWordTiming`
   的判定，否则「自动优选」永远不会问它。
