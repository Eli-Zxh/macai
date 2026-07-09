// tts.swift — macOS AVFoundation 语音合成工具
// 用法: ./tts <文本> [选项]
// 编译: swiftc -O -framework AVFoundation -framework Cocoa tts.swift -o tts

import Foundation
import AVFoundation
import Cocoa

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
      -h, --help                 显示此帮助信息

    示例:
      tts "Hello, world!"
      tts "你好世界" -v zh-CN
      tts "Hello" -v Samantha -r 0.6 -o hello.wav
      tts -f article.txt -v Ting-Ting -o output.aiff
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

class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var didFinish = false
    var didCancel = false
    let semaphore: DispatchSemaphore

    init(semaphore: DispatchSemaphore) {
        self.semaphore = semaphore
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        didFinish = true
        semaphore.signal()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        didCancel = true
        semaphore.signal()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        // 开始朗读
    }
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

    // 查找音色
    let voice = findVoice(name: config.voiceName)

    // 创建合成器
    let synthesizer = AVSpeechSynthesizer()
    let semaphore = DispatchSemaphore(value: 0)
    let delegate = TTSDelegate(semaphore: semaphore)
    synthesizer.delegate = delegate

    // 创建语音片段
    let utterance = AVSpeechUtterance(string: text)
    if let voice = voice {
        utterance.voice = voice
    }
    utterance.rate = config.rate
    utterance.pitchMultiplier = config.pitch
    utterance.volume = config.volume
    utterance.preUtteranceDelay = config.preDelay
    utterance.postUtteranceDelay = config.postDelay

    // 输出到文件或播放
    if let outputPath = config.outputPath {
        // 使用 NSSpeechSynthesizer 写入文件（所有 macOS 版本均支持）
        let voiceName: NSSpeechSynthesizer.VoiceName? = voice.map { NSSpeechSynthesizer.VoiceName(rawValue: $0.identifier) }
        guard let nsSpeech = NSSpeechSynthesizer(voice: voiceName) else {
            fputs("ERROR: 无法创建 NSSpeechSynthesizer\n", stderr)
            return false
        }

        // NSSpeechSynthesizer 使用 WPM（词/分钟），AVFoundation 使用 0.0-1.0
        // 默认 ~200 WPM 对应 rate=0.5
        nsSpeech.rate = config.rate * 400

        // 确定输出路径（NSSpeechSynthesizer 输出 AIFF 格式）
        let finalPath: String
        let ext = (outputPath as NSString).pathExtension.lowercased()
        if ext == "aiff" || ext == "aif" {
            finalPath = outputPath
        } else {
            // 非 AIFF 格式先输出 AIFF 再提示用户
            finalPath = (outputPath as NSString).deletingPathExtension + ".aiff"
            if ext != "aiff" && ext != "aif" {
                fputs("NOTE: NSSpeechSynthesizer 输出 AIFF 格式，文件保存为: \(finalPath)\n", stderr)
                fputs("      如需 WAV/CAF 格式，可用系统 say 命令或 ffmpeg 转换\n", stderr)
            }
        }

        let outputURL = URL(fileURLWithPath: finalPath)
        let success = nsSpeech.startSpeaking(text, to: outputURL)
        if !success {
            fputs("ERROR: 语音合成启动失败\n", stderr)
            return false
        }

        // 等待完成
        while nsSpeech.isSpeaking {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        fputs("已写入: \(finalPath)\n", stderr)
        return true
    } else {
        // 直接播放（使用 RunLoop 轮询，DispatchSemaphore 在 CLI 工具中会死锁）
        fputs("正在朗读...\n", stderr)
        synthesizer.speak(utterance)

        while synthesizer.isSpeaking {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return true
    }
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
