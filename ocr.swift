// ocr.swift — macOS Vision Framework OCR 工具（增强版）
// 用法: ./ocr <图片路径> [选项]
// 编译: swiftc -O -framework Cocoa -framework Vision ocr.swift -o ocr

import Cocoa
import Vision
import Foundation

// MARK: - 参数解析

struct OCRConfig {
    var inputPath: String = ""
    var languages: [String] = ["zh-Hans", "zh-Hant", "en-US"]
    var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    var outputFormat: String = "txt"  // txt | json
    var minTextHeight: Float = 0
    var usesLanguageCorrection: Bool = true
    var outputPath: String? = nil
    var batchDir: String? = nil
    var showHelp: Bool = false
    var autoDetectLanguage: Bool = false
}

func printHelp() {
    let help = """
    macOS Vision OCR 工具

    用法:
      ocr <图片路径> [选项]
      ocr -d <目录路径> [选项]

    选项:
      -l, --language <codes>      识别语言，逗号分隔（默认: zh-Hans,zh-Hant,en-US）
                                  支持: en-US, zh-Hans, zh-Hant, ja-JP, ko-KR, fr-FR,
                                  de-DE, es-ES, pt-BR, ru-RU, ar-SA, hi-IN, th-TH 等
      -m, --mode <fast|accurate>  识别模式（默认: accurate）
                                    fast     — 速度优先，适合实时预览
                                    accurate — 精度优先，适合文档处理
      -f, --format <txt|json>     输出格式（默认: txt）
                                    txt  — 纯文本，每行一个识别区域
                                    json — 结构化 JSON，含文本、坐标、置信度
      --min-text-height <float>   最小文字高度 0.0-1.0（默认: 0 不限制）
      --no-language-correction    禁用语言模型矫正
      --auto-detect-language      自动检测语言（macOS 13+）
      -d, --dir <目录>            批量处理目录下所有图片（png/jpg/jpeg/tiff/bmp）
      -o, --output <路径>         输出到文件（默认输出到 stdout）
      -h, --help                  显示此帮助信息

    示例:
      ocr image.png
      ocr image.png -f json -o result.json
      ocr image.png -l en-US,ja-JP -m fast
      ocr -d ./images/ -f json -o results.json
      ocr image.png --min-text-height 0.02 --no-language-correction
    """
    print(help)
}

func parseArgs() -> OCRConfig? {
    var config = OCRConfig()
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
        case "-l", "--language":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --language 需要参数\n", stderr)
                return nil
            }
            config.languages = args[i].split(separator: ",").map(String.init)
        case "-m", "--mode":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --mode 需要参数 (fast|accurate)\n", stderr)
                return nil
            }
            switch args[i] {
            case "fast": config.recognitionLevel = .fast
            case "accurate": config.recognitionLevel = .accurate
            default:
                fputs("ERROR: 未知识别模式 '\(args[i])'，可选: fast, accurate\n", stderr)
                return nil
            }
        case "-f", "--format":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --format 需要参数 (txt|json)\n", stderr)
                return nil
            }
            config.outputFormat = args[i]
            if config.outputFormat != "txt" && config.outputFormat != "json" {
                fputs("ERROR: 未知输出格式 '\(args[i])'，可选: txt, json\n", stderr)
                return nil
            }
        case "--min-text-height":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --min-text-height 需要参数\n", stderr)
                return nil
            }
            guard let val = Float(args[i]) else {
                fputs("ERROR: --min-text-height 需要数字参数\n", stderr)
                return nil
            }
            config.minTextHeight = val
        case "--no-language-correction":
            config.usesLanguageCorrection = false
        case "--auto-detect-language":
            config.autoDetectLanguage = true
        case "-d", "--dir":
            i += 1
            guard i < args.count else {
                fputs("ERROR: --dir 需要参数\n", stderr)
                return nil
            }
            config.batchDir = args[i]
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

    if config.batchDir == nil && config.inputPath.isEmpty {
        fputs("ERROR: 请指定图片路径或使用 -d 指定目录\n", stderr)
        return nil
    }

    return config
}

// MARK: - OCR 核心

struct OCRResult: Encodable {
    let file: String
    let texts: [TextRegion]
}

struct TextRegion: Encodable {
    let text: String
    let confidence: Double
    let boundingBox: BBox
}

struct BBox: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

func performOCR(imagePath: String, config: OCRConfig) -> OCRResult? {
    guard let image = NSImage(contentsOfFile: imagePath) else {
        fputs("ERROR: 无法加载图片 \(imagePath)\n", stderr)
        return nil
    }

    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fputs("ERROR: 无法转换 CGImage: \(imagePath)\n", stderr)
        return nil
    }

    let semaphore = DispatchSemaphore(value: 0)
    var regions: [TextRegion] = []
    var ocrError: String? = nil

    let request = VNRecognizeTextRequest { (request, error) in
        defer { semaphore.signal() }

        if let error = error {
            ocrError = "OCR 回调失败: \(error.localizedDescription)"
            return
        }

        guard let observations = request.results as? [VNRecognizedTextObservation] else {
            return
        }

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            regions.append(TextRegion(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                boundingBox: BBox(
                    x: round(box.origin.x * 10000) / 10000,
                    y: round(box.origin.y * 10000) / 10000,
                    width: round(box.width * 10000) / 10000,
                    height: round(box.height * 10000) / 10000
                )
            ))
        }
    }

    request.recognitionLevel = config.recognitionLevel
    request.recognitionLanguages = config.languages
    request.usesLanguageCorrection = config.usesLanguageCorrection
    request.minimumTextHeight = config.minTextHeight

    if config.autoDetectLanguage {
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        } else {
            fputs("WARNING: --auto-detect-language 需要 macOS 13+，已忽略\n", stderr)
        }
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
        semaphore.wait()
    } catch {
        fputs("ERROR: OCR 执行失败 \(error.localizedDescription)\n", stderr)
        return nil
    }

    if let err = ocrError {
        fputs("ERROR: \(err)\n", stderr)
        return nil
    }

    return OCRResult(file: imagePath, texts: regions)
}

// MARK: - 输出格式化

func formatOutput(result: OCRResult, format: String) -> String {
    switch format {
    case "json":
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "ERROR: JSON 编码失败"
    case "txt":
        return result.texts.map { $0.text }.joined(separator: "\n")
    default:
        return "ERROR: 未知格式 \(format)"
    }
}

// MARK: - 文件枚举

let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "heif", "webp"]

func listImageFiles(in directory: String) -> [String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: directory) else {
        fputs("ERROR: 无法访问目录 \(directory)\n", stderr)
        return []
    }

    var files: [String] = []
    while let file = enumerator.nextObject() as? String {
        let ext = (file as NSString).pathExtension.lowercased()
        if supportedExtensions.contains(ext) {
            files.append((directory as NSString).appendingPathComponent(file))
        }
    }
    return files.sorted()
}

// MARK: - 主入口

func main() {
    guard var config = parseArgs() else {
        exit(1)
    }

    if config.showHelp {
        printHelp()
        exit(0)
    }

    var output = ""

    if let batchDir = config.batchDir {
        // 批量模式
        let files = listImageFiles(in: batchDir)
        if files.isEmpty {
            fputs("ERROR: 目录 \(batchDir) 中未找到支持的图片文件\n", stderr)
            exit(1)
        }

        if config.outputFormat == "json" {
            var allResults: [OCRResult] = []
            for (idx, file) in files.enumerated() {
                fputs("[\(idx + 1)/\(files.count)] 处理: \(file)\n", stderr)
                if let result = performOCR(imagePath: file, config: config) {
                    allResults.append(result)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(allResults),
               let json = String(data: data, encoding: .utf8) {
                output = json
            }
        } else {
            var parts: [String] = []
            for (idx, file) in files.enumerated() {
                fputs("[\(idx + 1)/\(files.count)] 处理: \(file)\n", stderr)
                if let result = performOCR(imagePath: file, config: config) {
                    parts.append("=== \(file) ===")
                    parts.append(formatOutput(result: result, format: config.outputFormat))
                    parts.append("")
                }
            }
            output = parts.joined(separator: "\n")
        }
    } else {
        // 单文件模式
        guard let result = performOCR(imagePath: config.inputPath, config: config) else {
            exit(1)
        }
        output = formatOutput(result: result, format: config.outputFormat)
    }

    // 输出
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
