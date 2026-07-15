// tts.swift — macOS AVFoundation 语音合成工具
// 用法: ./tts <文本> [选项]
// 编译: swiftc -O -framework AVFoundation -framework Cocoa tts.swift -o tts

import Foundation
import AVFoundation
import Cocoa
import NaturalLanguage

// MARK: - 参数解析

struct TTSConfig {
    var text: String = ""
    var inputFile: String? = nil
    var voiceName: String? = nil
    var voiceLanguage: String? = nil
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitch: Float = 1.0
    var volume: Float = 1.0
    var preDelay: TimeInterval = 0
    var postDelay: TimeInterval = 0
    var outputPath: String? = nil
    var listVoices: Bool = false
    var showHelp: Bool = false
    var segmentLength: Int = 0  // 0 = 自动按句子切分; >0 = 每 N 个字符切分
}

func printHelp() {
    let help = """
    macOS 语音合成工具（基于 AVFoundation）

    用法:
      tts <文本> [选项]
      tts -f <文本文件> [选项]

    选项:
      -v, --voice <名称|语言>    音色选择
                                  可以是音色名称（如 "Samantha"）或语言代码（如 "zh-CN"）
                                  使用 --list-voices 查看所有可用音色
      -r, --rate <float>         语速 0.0-1.0（默认: 0.5）
                                  0.0 = 最慢, 0.5 = 正常, 1.0 = 最快
      -p, --pitch <float>        音调 0.5-2.0（默认: 1.0）
                                  0.5 = 低沉, 1.0 = 正常, 2.0 = 尖锐
      --volume <float>           音量 0.0-1.0（默认: 1.0）
      --pre-delay <seconds>      朗读前延迟秒数（默认: 0）
      --post-delay <seconds>     朗读后延迟秒数（默认: 0）
      -f, --file <路径>          从文件读取文本内容
      -o, --output <路径>        输出音频文件（支持 WAV/AIFF/CAF）
                                  格式由扩展名决定：
                                    .wav  — WAV 格式（macOS 13+）
                                    .aiff — AIFF 格式
                                    .caf  — Core Audio 格式
      --list-voices              列出所有可用音色
      --segment-length <n>       长文本分段合成（每段字符数，默认: 0 按句子自动切分）
                                  避免长文本合成失败，0 表示按标点自动分段
      -h, --help                 显示此帮助信息

    示例:
      tts "Hello, world!"
      tts "你好世界" -v zh-CN
      tts "Hello" -v Samantha -r 0.6 -o hello.wav
      tts -f article.txt -v Ting-Ting -o output.aiff
      tts -f long_article.txt --segment-length 200 -o output.aiff
      tts --list-voices
      tts --list-voices zh       # 列出中文音色

    提示:
      - 增强/高级音色需在 系统设置 → 辅助功能 → 语音内容 → 系统语音 中下载
      - macOS 13+ 支持直接写入 WAV 文件
      - 旧版 macOS 可通过 NSSpeechSynthesizer 输出 AIFF
    """
    print(help)
}

func parseArgs() -> TTSConfig? {
    var config = TTSConfig()
    let args = CommandLine.arguments
    var i = 1

    if args.count < 2 {
        printHelp()
        return nil
    }

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            config.showHelp = true
            return config
        case "--list-voices":
            config.listVoices = true
            // 可选跟随过滤关键词
            if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                i += 1
                config.voiceName = args[i]  // 复用为过滤关键词
            }
            return config
        case "-v", "--voice":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --voice 需要参数\n", stderr)
                return nil
            }
            config.voiceName = args[i]
        case "-r", "--rate":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --rate 需要参数\n", stderr)
                return nil
            }
            guard let val = Float(args[i]) else {
                fputs("ERROR: --rate 需要数字参数\n", stderr)
                return nil
            }
            config.rate = val
        case "-p", "--pitch":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --pitch 需要参数\n", stderr)
                return nil
            }
            guard let val = Float(args[i]) else {
                fputs("ERROR: --pitch 需要数字参数\n", stderr)
                return nil
            }
            config.pitch = val
        case "--volume":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --volume 需要参数\n", stderr)
                return nil
            }
            guard let val = Float(args[i]) else {
                fputs("ERROR: --volume 需要数字参数\n", stderr)
                return nil
            }
            config.volume = val
        case "--pre-delay":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --pre-delay 需要参数\n", stderr)
                return nil
            }
            guard let val = Double(args[i]) else {
                fputs("ERROR: --pre-delay 需要数字参数\n", stderr)
                return nil
            }
            config.preDelay = val
        case "--post-delay":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --post-delay 需要参数\n", stderr)
                return nil
            }
            guard let val = Double(args[i]) else {
                fputs("ERROR: --post-delay 需要数字参数\n", stderr)
                return nil
            }
            config.postDelay = val
        case "-f", "--file":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --file 需要参数\n", stderr)
                return nil
            }
            config.inputFile = args[i]
        case "-o", "--output":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --output 需要参数\n", stderr)
                return nil
            }
            config.outputPath = args[i]
        case "--segment-length":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --segment-length 需要参数（字符数）\n", stderr)
                return nil
            }
            guard let val = Int(args[i]), val >= 0 else {
                fputs("ERROR: --segment-length 需要非负整数参数\n", stderr)
                return nil
            }
            config.segmentLength = val
        default:
            if arg.hasPrefix("-") {
                fputs("ERROR: 未知选项 '\(arg)'\n", stderr)
                return nil
            }
            if config.text.isEmpty {
                config.text = arg
            } else {
                config.text += " " + arg
            }
        }
        i += 1
    }

    return config
}

// MARK: - 音色管理

func listAllVoices(filter: String? = nil) {
    let voices = AVSpeechSynthesisVoice.speechVoices()

    let qualityNames: [AVSpeechSynthesisVoiceQuality: String] = [
        .default: "标准",
        .enhanced: "增强",
        .premium: "高级"
    ]

    let genderNames: [AVSpeechSynthesisVoiceGender: String] = [
        .unspecified: "未知",
        .male: "男",
        .female: "女"
    ]

    var filtered = voices
    if let filter = filter {
        filtered = voices.filter {
            $0.name.localizedCaseInsensitiveContains(filter) ||
            $0.language.localizedCaseInsensitiveContains(filter) ||
            $0.identifier.localizedCaseInsensitiveContains(filter)
        }
    }

    // 按语言排序
    filtered.sort { $0.language < $1.language }

    print("名称                             语言       质量     性别   标识符")
    print(String(repeating: "-", count: 90))

    for voice in filtered {
        let quality = qualityNames[voice.quality] ?? "未知"
        let gender = genderNames[voice.gender] ?? "未知"
        let name = voice.name.padding(toLength: 30, withPad: " ", startingAt: 0)
        let lang = voice.language.padding(toLength: 10, withPad: " ", startingAt: 0)
        let qual = quality.padding(toLength: 8, withPad: " ", startingAt: 0)
        let gen = gender.padding(toLength: 6, withPad: " ", startingAt: 0)
        print("\(name) \(lang) \(qual) \(gen) \(voice.identifier)")
    }

    print("\n共 \(filtered.count) 个音色")
}

// MARK: - 语言检测与自动音色选择

func detectLanguage(text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let language = recognizer.dominantLanguage else { return nil }

    // NLLanguage 返回 BCP-47 代码，映射到语音音色语言代码
    let code = language.rawValue
    if code.hasPrefix("zh") {
        return "zh-CN"
    } else if code.hasPrefix("en") {
        return "en-US"
    } else if code.hasPrefix("ja") {
        return "ja-JP"
    } else if code.hasPrefix("ko") {
        return "ko-KR"
    } else {
        return code
    }
}

func autoSelectVoice(for text: String) -> AVSpeechSynthesisVoice? {
    guard let langCode = detectLanguage(text: text) else { return nil }

    // 优先选择 compact/premium 质量的音色
    let voices = AVSpeechSynthesisVoice.speechVoices()
    let langVoices = voices.filter { $0.language.hasPrefix(langCode) }

    // 优先选择非 eloquence 的音色（Eddy/Flo 等是特殊音色）
    if let voice = langVoices.first(where: {
        !$0.identifier.contains("eloquence") && !$0.identifier.contains("speech.synthesis")
    }) {
        return voice
    }

    // 回退到语言前缀匹配
    if let voice = AVSpeechSynthesisVoice(language: langCode) {
        return voice
    }

    return nil
}

func findVoice(name: String?) -> AVSpeechSynthesisVoice? {
    guard let name = name else { return nil }

    let voices = AVSpeechSynthesisVoice.speechVoices()

    // 1. 精确匹配名称
    if let voice = voices.first(where: { $0.name == name }) {
        return voice
    }

    // 2. 大小写不敏感匹配名称
    if let voice = voices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
        return voice
    }

    // 3. 作为语言代码匹配
    if let voice = AVSpeechSynthesisVoice(language: name) {
        return voice
    }

    // 4. 语言前缀匹配
    if let voice = voices.first(where: { $0.language.hasPrefix(name) }) {
        return voice
    }

    fputs("WARNING: 未找到匹配音色 '\(name)'，使用系统默认\n", stderr)
    return nil
}

// MARK: - TTS 核心

/// 将文本按句子边界或固定长度切分
func splitTextForTTS(_ text: String, segmentLength: Int) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    // 如果指定了固定长度，按长度切分（在句子边界处断开）
    if segmentLength > 0 {
        return splitByLength(text: trimmed, maxLen: segmentLength)
    }

    // 自动模式：按句子切分
    return splitBySentences(text: trimmed)
}

/// 按句子边界切分（中英文标点）
func splitBySentences(text: String) -> [String] {
    var sentences: [String] = []
    var current = ""

    let sentenceEndings: Set<Character> = [".", "。", "!", "！", "?", "？", ";", "；"]

    for char in text {
        current.append(char)
        if sentenceEndings.contains(char) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sentences.append(trimmed)
            }
            current = ""
        }
    }

    // 处理最后没有标点的部分
    let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !remaining.isEmpty {
        sentences.append(remaining)
    }

    // 如果只有 1 段且文本很长（>500 字符），尝试用逗号进一步切分
    if sentences.count == 1 && sentences[0].count > 500 {
        let commaSplit = splitByCommas(text: sentences[0])
        if commaSplit.count > 1 {
            return commaSplit
        }
    }

    return sentences.isEmpty ? [text] : sentences
}

/// 按逗号切分（次级断句）
func splitByCommas(text: String) -> [String] {
    var parts: [String] = []
    var current = ""

    for char in text {
        current.append(char)
        if char == "," || char == "，" {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
            current = ""
        }
    }

    let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !remaining.isEmpty {
        parts.append(remaining)
    }

    return parts.isEmpty ? [text] : parts
}

/// 按固定长度切分（在句子边界处断开）
func splitByLength(text: String, maxLen: Int) -> [String] {
    var segments: [String] = []
    var remaining = text

    while !remaining.isEmpty {
        if remaining.count <= maxLen {
            segments.append(remaining)
            break
        }

        // 在 maxLen 范围内找最后一个句子边界
        let searchRange = remaining.startIndex..<remaining.index(remaining.startIndex, offsetBy: maxLen)
        let searchText = String(remaining[searchRange])

        let sentenceEndings: Set<Character> = [".", "。", "!", "！", "?", "？", ";", "；"]
        var lastBreak: String.Index? = nil

        for (i, char) in searchText.enumerated() {
            if sentenceEndings.contains(char) {
                lastBreak = searchText.index(searchText.startIndex, offsetBy: i + 1)
            }
        }

        if let breakPoint = lastBreak, breakPoint > remaining.startIndex {
            let segment = String(remaining[remaining.startIndex..<breakPoint])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                segments.append(segment)
            }
            remaining = String(remaining[breakPoint...])
        } else {
            // 没有句子边界，在 maxLen 处硬切
            let cutPoint = remaining.index(remaining.startIndex, offsetBy: maxLen)
            let segment = String(remaining[remaining.startIndex..<cutPoint])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                segments.append(segment)
            }
            remaining = String(remaining[cutPoint...])
        }
    }

    return segments
}

/// 合并多个 AIFF 文件为一个
func concatenateAIFFFiles(paths: [String], outputPath: String) -> Bool {
    guard !paths.isEmpty else { return false }

    // 读取第一个文件获取格式
    guard let firstFile = try? AVAudioFile(forReading: URL(fileURLWithPath: paths[0])) else {
        fputs("ERROR: 无法读取临时音频文件\n", stderr)
        return false
    }

    let format = firstFile.processingFormat

    // 计算总帧数
    var totalFrames: AVAudioFrameCount = 0
    for path in paths {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { continue }
        totalFrames += AVAudioFrameCount(file.length)
    }

    // 创建输出文件
    guard let outputFile = try? AVAudioFile(forWriting: URL(fileURLWithPath: outputPath),
                                             settings: format.settings) else {
        fputs("ERROR: 无法创建输出文件: \(outputPath)\n", stderr)
        return false
    }

    // 逐文件追加
    for path in paths {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { continue }
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { continue }

        do {
            try file.read(into: buffer)
            try outputFile.write(from: buffer)
        } catch {
            fputs("WARNING: 合并音频段失败: \(error.localizedDescription)\n", stderr)
        }
    }

    return true
}

func synthesize(config: TTSConfig) -> Bool {
    // 获取文本
    var text = config.text
    if let inputFile = config.inputFile {
        do {
            text = try String(contentsOfFile: inputFile, encoding: .utf8)
        } catch {
            fputs("ERROR: 读取文件失败: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        fputs("ERROR: 文本为空\n", stderr)
        return false
    }

    // 查找音色（未指定时自动检测文本语言）
    let voice: AVSpeechSynthesisVoice?
    if let name = config.voiceName, !name.isEmpty {
        voice = findVoice(name: name)
    } else {
        voice = autoSelectVoice(for: text)
        if let v = voice {
            fputs("INFO: 自动检测到语言 \(v.language)，使用音色 \(v.name)\n", stderr)
        }
    }

    // 切分文本
    let segments = splitTextForTTS(text, segmentLength: config.segmentLength)

    if segments.count > 1 {
        fputs("INFO: 文本已切分为 \(segments.count) 段进行合成\n", stderr)
    }

    // 输出到文件
    if let outputPath = config.outputPath {
        return synthesizeToFile(segments: segments, voice: voice, config: config, outputPath: outputPath)
    } else {
        return synthesizeToPlayback(segments: segments, voice: voice, config: config)
    }
}

/// 分段合成到文件
func synthesizeToFile(segments: [String], voice: AVSpeechSynthesisVoice?, config: TTSConfig, outputPath: String) -> Bool {
    let voiceName: NSSpeechSynthesizer.VoiceName? = voice.map { NSSpeechSynthesizer.VoiceName(rawValue: $0.identifier) }

    // 确定最终输出路径（AIFF 格式）
    let finalPath: String
    let ext = (outputPath as NSString).pathExtension.lowercased()
    if ext == "aiff" || ext == "aif" {
        finalPath = outputPath
    } else {
        finalPath = (outputPath as NSString).deletingPathExtension + ".aiff"
        if ext != "aiff" && ext != "aif" {
            fputs("NOTE: NSSpeechSynthesizer 输出 AIFF 格式，文件保存为: \(finalPath)\n", stderr)
            fputs("      如需 WAV 格式，可用 ffmpeg -i \(finalPath) \(outputPath) 转换\n", stderr)
        }
    }

    // 如果只有一段，直接合成
    if segments.count == 1 {
        return synthesizeSingleToFile(text: segments[0], voiceName: voiceName, config: config, outputPath: finalPath)
    }

    // 多段：逐段合成到临时文件，然后合并
    let tempDir = NSTemporaryDirectory() + "tts_segments_\(ProcessInfo.processInfo.processIdentifier)"
    do {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    } catch {
        fputs("ERROR: 无法创建临时目录\n", stderr)
        return false
    }
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    var tempPaths: [String] = []

    for (i, segment) in segments.enumerated() {
        let tempPath = "\(tempDir)/segment_\(String(format: "%04d", i)).aiff"
        fputs("[\(i + 1)/\(segments.count)] 合成第 \(i + 1) 段 (\(segment.count) 字符) ...", stderr)

        if synthesizeSingleToFile(text: segment, voiceName: voiceName, config: config, outputPath: tempPath) {
            tempPaths.append(tempPath)
            fputs(" ✓\n", stderr)
        } else {
            fputs(" ✗ 失败\n", stderr)
        }
    }

    guard !tempPaths.isEmpty else {
        fputs("ERROR: 所有段合成失败\n", stderr)
        return false
    }

    // 合并所有临时文件
    fputs("合并 \(tempPaths.count) 段音频 ...", stderr)
    if concatenateAIFFFiles(paths: tempPaths, outputPath: finalPath) {
        fputs(" ✓\n", stderr)
        fputs("已写入: \(finalPath)\n", stderr)
        return true
    } else {
        fputs(" ✗\n", stderr)
        return false
    }
}

/// 单段合成到文件
func synthesizeSingleToFile(text: String, voiceName: NSSpeechSynthesizer.VoiceName?, config: TTSConfig, outputPath: String) -> Bool {
    guard let nsSpeech = NSSpeechSynthesizer(voice: voiceName) else {
        fputs("ERROR: 无法创建 NSSpeechSynthesizer\n", stderr)
        return false
    }

    nsSpeech.rate = config.rate * 400

    let outputURL = URL(fileURLWithPath: outputPath)
    let success = nsSpeech.startSpeaking(text, to: outputURL)
    if !success {
        fputs("ERROR: 语音合成启动失败\n", stderr)
        return false
    }

    // 等待合成开始
    let waitStart = Date()
    while !nsSpeech.isSpeaking && Date().timeIntervalSince(waitStart) < 5.0 {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // 等待合成结束
    while nsSpeech.isSpeaking {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    return true
}

/// 分段播放
func synthesizeToPlayback(segments: [String], voice: AVSpeechSynthesisVoice?, config: TTSConfig) -> Bool {
    let synthesizer = AVSpeechSynthesizer()

    fputs("正在朗读...\n", stderr)

    for (i, segment) in segments.enumerated() {
        let utterance = AVSpeechUtterance(string: segment)
        if let voice = voice {
            utterance.voice = voice
        }
        utterance.rate = config.rate
        utterance.pitchMultiplier = config.pitch
        utterance.volume = config.volume
        utterance.preUtteranceDelay = (i == 0) ? config.preDelay : 0
        utterance.postUtteranceDelay = (i == segments.count - 1) ? config.postDelay : 0

        synthesizer.speak(utterance)

        // 等待本段开始
        let startTime = Date()
        while !synthesizer.isSpeaking && Date().timeIntervalSince(startTime) < 5.0 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        // 等待本段结束
        while synthesizer.isSpeaking {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }

    return true
}

// MARK: - 主入口

func main() {
    guard let config = parseArgs() else {
        exit(1)
    }

    if config.showHelp {
        printHelp()
        exit(0)
    }

    if config.listVoices {
        listAllVoices(filter: config.voiceName)
        exit(0)
    }

    if config.text.isEmpty && config.inputFile == nil {
        fputs("ERROR: 请提供文本或使用 -f 指定文本文件\n", stderr)
        exit(1)
    }

    guard synthesize(config: config) else {
        exit(1)
    }
}

main()
