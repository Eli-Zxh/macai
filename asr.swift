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
      -h, --help                  显示此帮助信息

    示例:
      asr recording.wav
      asr meeting.m4a -l en-US --punctuation -f srt -o meeting.srt
      asr voice.wav --on-device -l zh-CN
      asr audio.wav --task-hint search --contextual "QoderWork,macOS"

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

func performASR(config: ASRConfig) -> String? {
    let fileURL = URL(fileURLWithPath: config.inputPath)

    // 检查文件存在
    guard FileManager.default.fileExists(atPath: config.inputPath) else {
        fputs("ERROR: 音频文件不存在: \(config.inputPath)\n", stderr)
        return nil
    }

    // 请求授权
    let authSemaphore = DispatchSemaphore(value: 0)
    var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    SFSpeechRecognizer.requestAuthorization { status in
        authStatus = status
        authSemaphore.signal()
    }
    authSemaphore.wait()

    guard authStatus == .authorized else {
        fputs("ERROR: 语音识别未授权。请在 系统偏好设置 → 隐私与安全 → 语音识别 中授权\n", stderr)
        return nil
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

    // 创建识别请求
    let request = SFSpeechURLRecognitionRequest(url: fileURL)
    request.shouldReportPartialResults = false
    request.taskHint = config.taskHint

    if #available(macOS 12.0, *) {
        request.addsPunctuation = config.addsPunctuation
    } else if config.addsPunctuation {
        fputs("WARNING: --punctuation 需要 macOS 12+，已忽略\n", stderr)
    }

    request.requiresOnDeviceRecognition = config.onDevice

    if !config.contextualStrings.isEmpty {
        request.contextualStrings = config.contextualStrings
    }

    // 执行识别
    let resultSemaphore = DispatchSemaphore(value: 0)
    var finalResult: SFSpeechRecognitionResult? = nil
    var resultError: Error? = nil

    fputs("正在识别: \(config.inputPath) ...\n", stderr)

    recognizer.recognitionTask(with: request) { result, error in
        if let error = error {
            resultError = error
            resultSemaphore.signal()
            return
        }
        guard let result = result else { return }
        if result.isFinal {
            finalResult = result
            resultSemaphore.signal()
        }
    }

    resultSemaphore.wait()

    if let error = resultError {
        fputs("ERROR: 识别失败: \(error.localizedDescription)\n", stderr)
        return nil
    }

    guard let result = finalResult else {
        fputs("ERROR: 未获得识别结果\n", stderr)
        return nil
    }

    // 提取结果
    switch config.outputFormat {
    case "srt":
        return formatSRT(result: result)
    case "txt":
        return result.bestTranscription.formattedString
    default:
        return result.bestTranscription.formattedString
    }
}

func formatSRT(result: SFSpeechRecognitionResult) -> String {
    let segments = result.bestTranscription.segments
    var srtLines: [String] = []
    var index = 1

    // 将 segments 按合理间隔分组（以标点或停顿为界）
    var currentText = ""
    var currentStart: TimeInterval = 0
    var currentEnd: TimeInterval = 0

    for segment in segments {
        if currentText.isEmpty {
            currentStart = segment.timestamp
        }

        currentText += segment.substring
        currentEnd = segment.timestamp + segment.duration

        // 如果下一个 segment 间隔超过 0.5 秒，或者当前 segment 以标点结尾，则分割
        let isLast = segment === segments.last!
        let nextGap: TimeInterval = {
            guard !isLast,
                  let nextIdx = segments.firstIndex(where: { $0 === segment }).map({ $0 + 1 }),
                  nextIdx < segments.count else { return 0 }
            return segments[nextIdx].timestamp - currentEnd
        }()

        let shouldSplit = isLast || nextGap > 0.5 ||
            currentText.hasSuffix("。") || currentText.hasSuffix(".") ||
            currentText.hasSuffix("？") || currentText.hasSuffix("?") ||
            currentText.hasSuffix("！") || currentText.hasSuffix("!") ||
            currentText.hasSuffix("，") || currentText.hasSuffix(",")

        if shouldSplit && !currentText.isEmpty {
            srtLines.append("\(index)")
            srtLines.append("\(formatSRTTime(currentStart)) --> \(formatSRTTime(currentEnd))")
            srtLines.append(currentText.trimmingCharacters(in: .whitespaces))
            srtLines.append("")
            index += 1
            currentText = ""
        }
    }

    return srtLines.joined(separator: "\n")
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
