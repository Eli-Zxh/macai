// asr.swift — macOS Speech Framework 语音识别工具
// 用法: ./asr <音频文件路径> [选项]
// 编译: swiftc -O -framework Speech -framework AVFoundation asr.swift -o asr

import Foundation
import Speech
import AVFoundation

// MARK: - 参数解析

struct ASRConfig {
    var inputPath: String = ""
    var locale: String = "zh-CN"
    var onDevice: Bool = false
    var taskHint: SFSpeechRecognitionTaskHint = .dictation
    var addsPunctuation: Bool = false
    var outputFormat: String = "txt"  // txt | srt
    var outputPath: String? = nil
    var showHelp: Bool = false
    var contextualStrings: [String] = []
    var chunkDuration: TimeInterval = 30  // 每段识别时长（秒）
}

func printHelp() {
    let help = """
    macOS Speech 语音识别工具

    用法:
      asr <音频文件路径> [选项]

    支持的音频格式: WAV, AIFF, AAC/M4A, MP3, CAF
    推荐参数: 16kHz, 16bit, 单声道

    选项:
      -l, --locale <code>         识别语言区域（默认: zh-CN）
                                  常用: en-US, zh-CN, zh-TW, ja-JP, ko-KR,
                                  fr-FR, de-DE, es-ES, pt-BR, ru-RU 等
      --on-device                 强制使用设备端识别（离线，需已下载语言模型）
      --task-hint <type>          任务类型提示（默认: dictation）
                                    dictation   — 通用听写，长文本
                                    search      — 短搜索词
                                    confirmation — 短确认词
      --punctuation               自动添加标点符号（macOS 12+）
      --contextual <词1,词2,...>   领域特定词汇，提升识别准确率
      -f, --format <txt|srt>      输出格式（默认: txt）
                                    txt — 纯文本
                                    srt — 带时间戳的 SRT 字幕格式
      -o, --output <路径>         输出到文件（默认输出到 stdout）
      --chunk-duration <秒>       长音频分段识别间隔（默认: 30）
                                  将长音频切分为指定时长的段逐段识别，避免超长音频识别失败
      -h, --help                  显示此帮助信息

    示例:
      asr recording.wav
      asr meeting.m4a -l en-US --punctuation -f srt -o meeting.srt
      asr voice.wav --on-device -l zh-CN
      asr audio.wav --task-hint search --contextual "QoderWork,macOS"
      asr long_meeting.wav --chunk-duration 60 -f srt -o meeting.srt

    注意:
      - 首次运行需要授权语音识别权限（系统偏好设置 → 隐私与安全 → 语音识别）
      - 设备端识别需要先在 系统设置 → 辅助功能 → 语音内容 → 语言 中下载模型
      - 服务端识别需要网络连接，有速率限制（约 1000 次/小时）
    """
    print(help)
}

func parseArgs() -> ASRConfig? {
    var config = ASRConfig()
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
        case "-l", "--locale":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --locale 需要参数\n", stderr)
                return nil
            }
            config.locale = args[i]
        case "--on-device":
            config.onDevice = true
        case "--task-hint":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --task-hint 需要参数\n", stderr)
                return nil
            }
            switch args[i] {
            case "dictation": config.taskHint = .dictation
            case "search": config.taskHint = .search
            case "confirmation": config.taskHint = .confirmation
            default:
                fputs("ERROR: 未知任务类型 '\(args[i])'，可选: dictation, search, confirmation\n", stderr)
                return nil
            }
        case "--punctuation":
            config.addsPunctuation = true
        case "--contextual":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --contextual 需要参数\n", stderr)
                return nil
            }
            config.contextualStrings = args[i].split(separator: ",").map(String.init)
        case "-f", "--format":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --format 需要参数 (txt|srt)\n", stderr)
                return nil
            }
            config.outputFormat = args[i]
            if config.outputFormat != "txt" && config.outputFormat != "srt" {
                fputs("ERROR: 未知输出格式 '\(args[i])'，可选: txt, srt\n", stderr)
                return nil
            }
        case "-o", "--output":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --output 需要参数\n", stderr)
                return nil
            }
            config.outputPath = args[i]
        case "--chunk-duration":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --chunk-duration 需要参数（秒数）\n", stderr)
                return nil
            }
            guard let val = Double(args[i]), val > 0 else {
                fputs("ERROR: --chunk-duration 需要正数参数\n", stderr)
                return nil
            }
            config.chunkDuration = val
        default:
            if arg.hasPrefix("-") {
                fputs("ERROR: 未知选项 '\(arg)'\n", stderr)
                return nil
            }
            if config.inputPath.isEmpty {
                config.inputPath = arg
            } else {
                fputs("ERROR: 多余的参数 '\(arg)'\n", stderr)
                return nil
            }
        }
        i += 1
    }

    if config.inputPath.isEmpty {
        fputs("ERROR: 请指定音频文件路径\n", stderr)
        return nil
    }

    return config
}

// MARK: - SRT 时间格式化

func formatSRTTime(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    let secs = Int(seconds) % 60
    let millis = Int((seconds - floor(seconds)) * 1000)
    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
}

// MARK: - 语音识别核心

struct Segment {
    let text: String
    let startTime: TimeInterval
    let duration: TimeInterval
    let confidence: Float
}

/// 将音频文件切分为临时文件块，返回临时文件路径数组和每块的起始时间
func splitAudioIntoChunks(fileURL: URL, chunkDuration: TimeInterval) -> ([(path: String, startTime: TimeInterval)], TimeInterval)? {
    guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
        fputs("ERROR: 无法读取音频文件\n", stderr)
        return nil
    }

    let sampleRate = audioFile.processingFormat.sampleRate
    let totalFrames = AVAudioFrameCount(audioFile.length)
    let framesPerChunk = AVAudioFrameCount(chunkDuration * sampleRate)

    // 如果音频时长小于 chunk 时长，不需要切分
    if totalFrames <= framesPerChunk {
        return nil
    }

    let totalDuration = Double(totalFrames) / sampleRate
    let chunkCount = Int(ceil(Double(totalFrames) / Double(framesPerChunk)))
    let tempDir = NSTemporaryDirectory() + "asr_chunks_\(ProcessInfo.processInfo.processIdentifier)"

    do {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    } catch {
        fputs("ERROR: 无法创建临时目录\n", stderr)
        return nil
    }

    var chunks: [(path: String, startTime: TimeInterval)] = []

    for i in 0..<chunkCount {
        let startFrame = AVAudioFramePosition(Double(i) * Double(framesPerChunk))
        let remainingFrames = totalFrames - AVAudioFrameCount(startFrame)
        let framesToRead = min(framesPerChunk, remainingFrames)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: framesToRead) else {
            fputs("ERROR: 无法创建音频缓冲区\n", stderr)
            cleanupChunks(tempDir: tempDir)
            return nil
        }

        do {
            audioFile.framePosition = startFrame
            try audioFile.read(into: buffer, frameCount: framesToRead)
        } catch {
            fputs("ERROR: 读取音频第 \(i + 1) 段失败: \(error.localizedDescription)\n", stderr)
            cleanupChunks(tempDir: tempDir)
            return nil
        }

        let chunkPath = "\(tempDir)/chunk_\(String(format: "%04d", i)).wav"
        let chunkURL = URL(fileURLWithPath: chunkPath)

        // 写入 WAV 格式
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: audioFile.processingFormat.channelCount,
                                         interleaved: false)!
        guard let output = try? AVAudioFile(forWriting: chunkURL, settings: outputFormat.settings) else {
            fputs("ERROR: 无法创建临时音频文件\n", stderr)
            cleanupChunks(tempDir: tempDir)
            return nil
        }

        do {
            try output.write(from: buffer)
        } catch {
            fputs("ERROR: 写入临时音频失败: \(error.localizedDescription)\n", stderr)
            cleanupChunks(tempDir: tempDir)
            return nil
        }

        let startTime = Double(startFrame) / sampleRate
        chunks.append((path: chunkPath, startTime: startTime))
    }

    fputs("音频总时长 \(String(format: "%.1f", totalDuration))s，切分为 \(chunkCount) 段（每段 \(Int(chunkDuration))s）\n", stderr)
    return (chunks, totalDuration)
}

func cleanupChunks(tempDir: String) {
    try? FileManager.default.removeItem(atPath: tempDir)
}

/// 对单个音频文件执行识别
func recognizeSingleChunk(fileURL: URL, config: ASRConfig, recognizer: SFSpeechRecognizer) -> (transcript: String, result: SFSpeechRecognitionResult)? {
    let request = SFSpeechURLRecognitionRequest(url: fileURL)
    request.shouldReportPartialResults = true
    request.taskHint = config.taskHint

    if #available(macOS 12.0, *) {
        request.addsPunctuation = config.addsPunctuation || config.outputFormat == "srt"
    }

    request.requiresOnDeviceRecognition = config.onDevice

    if !config.contextualStrings.isEmpty {
        request.contextualStrings = config.contextualStrings
    }

    var isDone = false
    var allResults: [SFSpeechRecognitionResult] = []
    var resultError: Error? = nil

    recognizer.recognitionTask(with: request) { result, error in
        if let error = error {
            resultError = error
            isDone = true
            return
        }
        guard let result = result else { return }
        allResults.append(result)
        if result.isFinal {
            isDone = true
        }
    }

    while !isDone {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    if let error = resultError {
        fputs("WARNING: 段识别出错: \(error.localizedDescription)\n", stderr)
        return nil
    }

    guard !allResults.isEmpty else { return nil }

    let bestResult = allResults.max(by: { $0.bestTranscription.formattedString.count < $1.bestTranscription.formattedString.count })!
    return (bestResult.bestTranscription.formattedString, bestResult)
}

func performASR(config: ASRConfig) -> String? {
    let fileURL = URL(fileURLWithPath: config.inputPath)

    // 检查文件存在
    guard FileManager.default.fileExists(atPath: config.inputPath) else {
        fputs("ERROR: 音频文件不存在: \(config.inputPath)\n", stderr)
        return nil
    }

    // 检查授权状态（不调用 requestAuthorization，CLI 工具中会崩溃）
    let authStatus = SFSpeechRecognizer.authorizationStatus()

    if authStatus != .authorized {
        fputs("WARNING: 语音识别可能未授权。如果识别结果不完整，请从 Terminal.app 运行本工具\n", stderr)
        fputs("  系统设置 → 隐私与安全 → 语音识别 → 允许 Terminal\n", stderr)
    }

    // 创建识别器
    let locale = Locale(identifier: config.locale)
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
        fputs("ERROR: 不支持的语言区域: \(config.locale)\n", stderr)
        return nil
    }

    // 检查设备端识别可用性
    if config.onDevice {
        guard recognizer.supportsOnDeviceRecognition else {
            fputs("ERROR: 语言区域 \(config.locale) 不支持设备端识别\n", stderr)
            fputs("提示: 请在 系统设置 → 辅助功能 → 语音内容 → 语言 中下载模型\n", stderr)
            return nil
        }
    }

    // 获取音频总时长
    let audioDuration: TimeInterval = {
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else { return 0 }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }()

    // 判断是否需要分段
    let needsChunking = audioDuration > config.chunkDuration && config.chunkDuration > 0

    if needsChunking {
        return performChunkedASR(config: config, recognizer: recognizer, fileURL: fileURL, audioDuration: audioDuration)
    } else {
        return performSingleASR(config: config, recognizer: recognizer, fileURL: fileURL, audioDuration: audioDuration)
    }
}

/// 单段识别（短音频，原始逻辑）
func performSingleASR(config: ASRConfig, recognizer: SFSpeechRecognizer, fileURL: URL, audioDuration: TimeInterval) -> String? {
    fputs("正在识别: \(config.inputPath) ...\n", stderr)

    guard let chunkResult = recognizeSingleChunk(fileURL: fileURL, config: config, recognizer: recognizer) else {
        fputs("ERROR: 未获得识别结果\n", stderr)
        return nil
    }

    let transcript = chunkResult.transcript
    fputs("识别完成: \(transcript.count) 字符\n", stderr)

    switch config.outputFormat {
    case "srt":
        return formatSRT(transcript: transcript, result: chunkResult.result, audioDuration: audioDuration)
    case "txt":
        return transcript
    default:
        return transcript
    }
}

/// 分段识别（长音频）
func performChunkedASR(config: ASRConfig, recognizer: SFSpeechRecognizer, fileURL: URL, audioDuration: TimeInterval) -> String? {
    guard let (chunks, _) = splitAudioIntoChunks(fileURL: fileURL, chunkDuration: config.chunkDuration) else {
        // 切分失败，回退到单段识别
        fputs("WARNING: 音频切分失败，尝试整体识别\n", stderr)
        return performSingleASR(config: config, recognizer: recognizer, fileURL: fileURL, audioDuration: audioDuration)
    }

    defer { cleanupChunks(tempDir: NSTemporaryDirectory() + "asr_chunks_\(ProcessInfo.processInfo.processIdentifier)") }

    // 逐段识别
    var chunkResults: [(transcript: String, result: SFSpeechRecognitionResult, startTime: TimeInterval)] = []
    let startTime = Date()

    for (i, chunk) in chunks.enumerated() {
        fputs("[\(i + 1)/\(chunks.count)] 识别 \(String(format: "%.1f", chunk.startTime))s-\(String(format: "%.1f", min(chunk.startTime + config.chunkDuration, audioDuration)))s ...", stderr)

        let chunkURL = URL(fileURLWithPath: chunk.path)
        if let result = recognizeSingleChunk(fileURL: chunkURL, config: config, recognizer: recognizer) {
            chunkResults.append((transcript: result.transcript, result: result.result, startTime: chunk.startTime))
            fputs(" ✓ \(result.transcript.count) 字符\n", stderr)
        } else {
            fputs(" ✗ 无结果\n", stderr)
        }
    }

    guard !chunkResults.isEmpty else {
        fputs("ERROR: 所有段均未获得识别结果\n", stderr)
        return nil
    }

    let elapsed = Date().timeIntervalSince(startTime)
    let totalChars = chunkResults.reduce(0) { $0 + $1.transcript.count }
    fputs("分段识别完成: \(chunkResults.count) 段, \(totalChars) 字符, 耗时 \(String(format: "%.1f", elapsed))s\n", stderr)

    // 合并结果
    switch config.outputFormat {
    case "srt":
        return mergeSRTResults(chunkResults: chunkResults, audioDuration: audioDuration)
    case "txt":
        return chunkResults.map { $0.transcript }.joined(separator: "")
    default:
        return chunkResults.map { $0.transcript }.joined(separator: "")
    }
}

/// 合并分段 SRT 结果
func mergeSRTResults(chunkResults: [(transcript: String, result: SFSpeechRecognitionResult, startTime: TimeInterval)], audioDuration: TimeInterval) -> String {
    var allSentences: [(text: String, globalStart: TimeInterval, globalEnd: TimeInterval)] = []

    for (chunkIdx, chunk) in chunkResults.enumerated() {
        let segments = chunk.result.bestTranscription.segments
        let chunkTranscript = chunk.transcript

        // 按句子边界拆分
        var sentences = splitSentences(chunkTranscript)
        if sentences.count <= 1 && segments.count > 1 {
            let gapSplit = splitBySegmentGaps(transcript: chunkTranscript, segments: segments)
            if gapSplit.count > 1 {
                sentences = gapSplit
            }
        }

        guard !sentences.isEmpty else { continue }

        // 计算本段时长：优先用 segments，否则用下一段起始时间差或音频总时长
        let chunkDuration: TimeInterval = {
            if let lastSeg = segments.last {
                let segEnd = lastSeg.timestamp + lastSeg.duration
                if segEnd > 0 { return segEnd }
            }
            // 用下一段的起始时间减去本段起始时间
            if chunkIdx + 1 < chunkResults.count {
                return chunkResults[chunkIdx + 1].startTime - chunk.startTime
            }
            // 最后一段：用音频总时长减去本段起始时间
            return audioDuration - chunk.startTime
        }()

        // 用字符比例分配本段时长
        let totalChars = sentences.reduce(0) { $0 + $1.count }
        var currentTime: TimeInterval = 0
        for sentence in sentences {
            let proportion = totalChars > 0 ? Double(sentence.count) / Double(totalChars) : 1.0 / Double(sentences.count)
            let sentenceDuration = max(chunkDuration, 0.5) * proportion
            let globalStart = chunk.startTime + currentTime
            let globalEnd = chunk.startTime + currentTime + sentenceDuration
            allSentences.append((text: sentence, globalStart: globalStart, globalEnd: globalEnd))
            currentTime += sentenceDuration
        }
    }

    guard !allSentences.isEmpty else { return "" }

    // 生成 SRT
    var srtLines: [String] = []
    for (i, sentence) in allSentences.enumerated() {
        srtLines.append("\(i + 1)")
        srtLines.append("\(formatSRTTime(sentence.globalStart)) --> \(formatSRTTime(sentence.globalEnd))")
        srtLines.append(sentence.text)
        srtLines.append("")
    }

    return srtLines.joined(separator: "\n")
}

func formatSRT(transcript: String, result: SFSpeechRecognitionResult, audioDuration: TimeInterval) -> String {
    let segments = result.bestTranscription.segments

    // 也尝试从 segments 获取时长
    let segmentDuration: TimeInterval = {
        guard let lastSeg = segments.last else { return 0 }
        return lastSeg.timestamp + lastSeg.duration
    }()

    // 优先使用 segment 时长（更精确），否则使用音频文件时长
    let totalDuration = segmentDuration > 0 ? segmentDuration : audioDuration

    // 按句子边界拆分文本（中英文标点）
    var sentences = splitSentences(transcript)

    // 如果标点拆分只有 1 句，尝试用 segments 时间间隔拆分
    if sentences.count <= 1 && segments.count > 1 {
        let gapSplit = splitBySegmentGaps(transcript: transcript, segments: segments)
        if gapSplit.count > 1 {
            sentences = gapSplit
        }
    }

    guard !sentences.isEmpty else { return "" }

    // 如果总时长为 0，用均匀分配（每句 1 秒）
    guard totalDuration > 0 else {
        var srtLines: [String] = []
        for (i, sentence) in sentences.enumerated() {
            let start = Double(i) * 1.0
            let end = start + 1.0
            srtLines.append("\(i + 1)")
            srtLines.append("\(formatSRTTime(start)) --> \(formatSRTTime(end))")
            srtLines.append(sentence)
            srtLines.append("")
        }
        return srtLines.joined(separator: "\n")
    }

    // 按字符数比例分配时间戳
    let totalChars = sentences.reduce(0) { $0 + $1.count }
    var srtLines: [String] = []
    var currentTime: TimeInterval = 0

    for (i, sentence) in sentences.enumerated() {
        let proportion = Double(sentence.count) / Double(max(totalChars, 1))
        let sentenceDuration = totalDuration * proportion
        let endTime = currentTime + sentenceDuration

        srtLines.append("\(i + 1)")
        srtLines.append("\(formatSRTTime(currentTime)) --> \(formatSRTTime(endTime))")
        srtLines.append(sentence)
        srtLines.append("")

        currentTime = endTime
    }

    return srtLines.joined(separator: "\n")
}

/// 按句子边界拆分文本（支持中英文标点）
func splitSentences(_ text: String) -> [String] {
    var sentences: [String] = []
    var current = ""

    let sentenceEndings: Set<Character> = [".", "。", "!", "！", "?", "？", ";", "；", ",", "，"]

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

    return sentences
}

/// 利用 word-level segments 的时间间隔拆分句子（间隔 > 0.3s 视为句间停顿）
func splitBySegmentGaps(transcript: String, segments: [SFTranscriptionSegment]) -> [String] {
    guard segments.count > 1 else { return [transcript] }

    // 建立每个 word 在 transcript 中的位置映射
    let words = transcript.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard words.count > 1 else { return [transcript] }

    // 找到 segments 中的大间隔（> 0.3s）
    var splitIndices: [Int] = []
    for i in 1..<segments.count {
        let gap = segments[i].timestamp - (segments[i-1].timestamp + segments[i-1].duration)
        if gap > 0.3 {
            splitIndices.append(i)
        }
    }

    guard !splitIndices.isEmpty else { return [transcript] }

    // 将 segment 索引映射到 word 索引，然后映射到字符位置
    // segments 通常对应 words（一个 segment 对应一个 word）
    var sentences: [String] = []
    var lastWordEnd = 0

    for segIdx in splitIndices {
        // segment 索引近似对应 word 索引
        let wordIdx = min(segIdx, words.count)
        // 计算这个 word 之前的字符位置
        let charPos = words.prefix(wordIdx).joined(separator: " ").count
        if charPos > lastWordEnd {
            let sentence = String(transcript[transcript.startIndex..<transcript.index(transcript.startIndex, offsetBy: charPos)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            lastWordEnd = charPos
        }
    }

    // 添加剩余部分
    if lastWordEnd < transcript.count {
        let remaining = String(transcript[transcript.index(transcript.startIndex, offsetBy: lastWordEnd)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }
    }

    return sentences.isEmpty ? [transcript] : sentences
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

    guard let output = performASR(config: config) else {
        exit(1)
    }

    if let outputPath = config.outputPath {
        do {
            try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
            fputs("已写入: \(outputPath)\n", stderr)
        } catch {
            fputs("ERROR: 写入文件失败: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    } else {
        print(output)
    }
}

main()
