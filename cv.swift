// cv.swift — macOS 原生计算机视觉工具
// 功能：人物分割 / 前景物体分割 / 图片美学评分
// 编译：swiftc -O -framework Vision -framework CoreImage -framework ImageIO -framework AppKit -framework Cocoa cv.swift -o cv

import Foundation
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - 配置

struct CVConfig {
    var inputPath: String = ""
    var outputDir: String? = nil
    var mode: String = "person"              // person | foreground | aesthetics
    var quality: String = "balanced"       // fast | balanced | accurate
    var outputFormat: String = "png"       // png | mask | json
    var allInstances: Bool = false
    var batchDir: String? = nil
}

// MARK: - 参数解析

func printHelp() {
    let help = """
    cv — macOS 原生计算机视觉工具

    用法: cv <图片路径> [选项]

    模式（-m）:
      person       人物分割（仅人物，macOS 12+）（默认）
      foreground   前景物体分割（所有物体，macOS 14+）
      aesthetics   图片美学评分（macOS 15+）

    选项:
      -m, --mode <模式>        处理模式（默认: person）
      -q, --quality <质量>     分割质量: fast | balanced | accurate（默认: balanced）
                               仅 person/foreground 模式有效
      -o, --output <路径>      输出文件路径或目录
      -f, --format <格式>      输出格式: png | mask | json
                               person/foreground: png（抠图）| mask（蒙版）| json（信息）
                               aesthetics: txt | json
      --all-instances          foreground 模式: 分别导出每个物体
      --batch <目录>           批量处理目录下所有图片
      -h, --help               显示此帮助信息

    示例:
      cv photo.jpg                              # 人物分割抠图
      cv photo.jpg -m person -o person.png      # 人物分割，输出 PNG
      cv photo.jpg -m foreground --all-instances -o ./out/  # 分割所有物体
      cv photo.jpg -m aesthetics -f json        # 美学评分 JSON 输出
      cv --batch ./photos/ -m person -o ./out/  # 批量抠图

    支持格式: JPEG, PNG, TIFF, HEIC, BMP 等所有 macOS 支持的图片格式
    输出格式: PNG（支持透明通道）
    """
    print(help)
}

func parseArgs() -> CVConfig? {
    var config = CVConfig()
    let args = Array(CommandLine.arguments.dropFirst())

    if args.isEmpty {
        printHelp()
        return nil
    }

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            printHelp()
            exit(0)
        case "-m", "--mode":
            i += 1
            guard i < args.count else { fputs("ERROR: --mode 需要参数\n", stderr); return nil }
            config.mode = args[i]
        case "-q", "--quality":
            i += 1
            guard i < args.count else { fputs("ERROR: --quality 需要参数\n", stderr); return nil }
            config.quality = args[i]
        case "-o", "--output":
            i += 1
            guard i < args.count else { fputs("ERROR: --output 需要参数\n", stderr); return nil }
            config.outputDir = args[i]
        case "-f", "--format":
            i += 1
            guard i < args.count else { fputs("ERROR: --format 需要参数\n", stderr); return nil }
            config.outputFormat = args[i]
        case "--all-instances":
            config.allInstances = true
        case "--batch":
            i += 1
            guard i < args.count else { fputs("ERROR: --batch 需要参数\n", stderr); return nil }
            config.batchDir = args[i]
        default:
            if arg.hasPrefix("-") {
                fputs("ERROR: 未知选项: \(arg)\n", stderr)
                return nil
            }
            config.inputPath = arg
        }
        i += 1
    }

    // 验证
    let validModes = ["person", "foreground", "aesthetics"]
    guard validModes.contains(config.mode) else {
        fputs("ERROR: 无效模式 '\(config.mode)'，可选: \(validModes.joined(separator: ", "))\n", stderr)
        return nil
    }

    if config.batchDir == nil && config.inputPath.isEmpty {
        fputs("ERROR: 请指定图片路径或使用 --batch 指定目录\n", stderr)
        return nil
    }

    return config
}

// MARK: - 图像 I/O

func loadCGImage(from path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        fputs("ERROR: 无法读取图片: \(path)\n", stderr)
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func savePNG(cgImage: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        fputs("ERROR: 无法创建输出文件: \(path)\n", stderr)
        return false
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        fputs("ERROR: 写入 PNG 失败: \(path)\n", stderr)
        return false
    }
    return true
}

func ensureDirectory(_ path: String) {
    if !FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}

func outputName(for inputPath: String, suffix: String = "", ext: String = "png") -> String {
    let base = (inputPath as NSString).deletingPathExtension
    let name = (base as NSString).lastPathComponent
    return "\(name)\(suffix).\(ext)"
}

func resolveOutputPath(config: CVConfig, inputPath: String, suffix: String = "", ext: String = "png") -> String {
    if let output = config.outputDir {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: output, isDirectory: &isDir), isDir.boolValue {
            return (output as NSString).appendingPathComponent(outputName(for: inputPath, suffix: suffix, ext: ext))
        }
        return output
    }
    return outputName(for: inputPath, suffix: suffix, ext: ext)
}

// MARK: - CVPixelBuffer → CGImage

func pixelBufferToCGImage(_ pixelBuffer: CVPixelBuffer, isMask: Bool = false) -> CGImage? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()

    if isMask {
        // 蒙版模式：灰度图
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return cgImage
    } else {
        // 软蒙版转 alpha
        let alphaFilter = CIFilter(name: "CIMaskToAlpha")!
        alphaFilter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let alphaOutput = alphaFilter.outputImage,
              let cgImage = context.createCGImage(alphaOutput, from: alphaOutput.extent) else {
            return nil
        }
        return cgImage
    }
}

// MARK: - 人物分割

func personSegmentation(config: CVConfig, cgImage: CGImage, inputPath: String) -> Bool {
    let request = VNGeneratePersonSegmentationRequest()

    switch config.quality {
    case "fast": request.qualityLevel = .fast
    case "accurate": request.qualityLevel = .accurate
    default: request.qualityLevel = .balanced
    }

    let handler = VNImageRequestHandler(cgImage: cgImage)
    do {
        try handler.perform([request])
    } catch {
        fputs("ERROR: 人物分割失败: \(error.localizedDescription)\n", stderr)
        return false
    }

    guard let observation = request.results?.first else {
        fputs("ERROR: 未检测到人物\n", stderr)
        return false
    }

    let mask = observation.pixelBuffer
    fputs("检测到人物，蒙版分辨率: \(CVPixelBufferGetWidth(mask))x\(CVPixelBufferGetHeight(mask))\n", stderr)

    switch config.outputFormat {
    case "mask":
        // 输出灰度蒙版
        guard let maskCG = pixelBufferToCGImage(mask, isMask: true) else {
            fputs("ERROR: 蒙版转换失败\n", stderr)
            return false
        }
        let outPath = resolveOutputPath(config: config, inputPath: inputPath, suffix: "_person_mask")
        return savePNG(cgImage: maskCG, to: outPath)

    case "json":
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        // 计算人物像素占比
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        let baseAddr = CVPixelBufferGetBaseAddress(mask)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        var personPixels = 0
        for y in 0..<height {
            for x in 0..<width {
                let pixel = baseAddr.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self)
                if pixel > 127 { personPixels += 1 }
            }
        }
        CVPixelBufferUnlockBaseAddress(mask, .readOnly)
        let ratio = Double(personPixels) / Double(width * height)
        let json: [String: Any] = [
            "mode": "person",
            "width": width, "height": height,
            "person_pixels": personPixels,
            "person_ratio": String(format: "%.4f", ratio),
            "quality": config.quality
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            if let outPath = config.outputDir {
                try? jsonStr.write(toFile: outPath, atomically: true, encoding: .utf8)
            } else {
                print(jsonStr)
            }
        }
        return true

    default: // png — 抠图（原图 × 蒙版）
        guard let composited = compositeWithMask(cgImage: cgImage, mask: mask) else {
            fputs("ERROR: 合成失败\n", stderr)
            return false
        }
        let outPath = resolveOutputPath(config: config, inputPath: inputPath, suffix: "_person")
        return savePNG(cgImage: composited, to: outPath)
    }
}

// MARK: - 前景物体分割

func foregroundSegmentation(config: CVConfig, cgImage: CGImage, inputPath: String) -> Bool {
    let ciImage = CIImage(cgImage: cgImage)
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(ciImage: ciImage)

    do {
        try handler.perform([request])
    } catch {
        fputs("ERROR: 前景分割失败: \(error.localizedDescription)\n", stderr)
        return false
    }

    guard let observation = request.results?.first else {
        fputs("ERROR: 未检测到前景物体\n", stderr)
        return false
    }

    let allInstances = observation.allInstances
    fputs("检测到 \(allInstances.count) 个前景物体\n", stderr)

    switch config.outputFormat {
    case "json":
        var instances: [[String: Any]] = []
        for idx in allInstances {
            instances.append(["index": idx])
        }
        let json: [String: Any] = [
            "mode": "foreground",
            "instance_count": allInstances.count,
            "instances": instances
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            if let outPath = config.outputDir {
                try? jsonStr.write(toFile: outPath, atomically: true, encoding: .utf8)
            } else {
                print(jsonStr)
            }
        }
        return true

    case "mask":
        let maskCG = pixelBufferToCGImage(observation.instanceMask, isMask: true)
        guard let mask = maskCG else {
            fputs("ERROR: 蒙版转换失败\n", stderr)
            return false
        }
        let outPath = resolveOutputPath(config: config, inputPath: inputPath, suffix: "_fg_mask")
        return savePNG(cgImage: mask, to: outPath)

    default: // png
        if config.allInstances {
            // 分别导出每个物体
            let outDir = config.outputDir ?? "."
            ensureDirectory(outDir)
            var success = true
            for idx in allInstances {
                do {
                    let mask = try observation.generateScaledMaskForImage(
                        forInstances: IndexSet([idx]), from: handler
                    )
                    guard let composited = compositeWithMask(cgImage: cgImage, mask: mask) else {
                        fputs("WARNING: 物体 #\(idx) 合成失败\n", stderr)
                        continue
                    }
                    let outPath = (outDir as NSString).appendingPathComponent(
                        outputName(for: inputPath, suffix: "_fg_\(idx)")
                    )
                    if !savePNG(cgImage: composited, to: outPath) { success = false }
                    else { fputs("  物体 #\(idx) → \(outPath)\n", stderr) }
                } catch {
                    fputs("WARNING: 物体 #\(idx) 蒙版生成失败: \(error.localizedDescription)\n", stderr)
                }
            }
            return success
        } else {
            // 导出所有物体合成为一张
            do {
                let mask = try observation.generateScaledMaskForImage(
                    forInstances: allInstances, from: handler
                )
                guard let composited = compositeWithMask(cgImage: cgImage, mask: mask) else {
                    fputs("ERROR: 合成失败\n", stderr)
                    return false
                }
                let outPath = resolveOutputPath(config: config, inputPath: inputPath, suffix: "_fg")
                return savePNG(cgImage: composited, to: outPath)
            } catch {
                fputs("ERROR: 蒙版生成失败: \(error.localizedDescription)\n", stderr)
                return false
            }
        }
    }
}

// MARK: - 美学评分

func aestheticsScoring(config: CVConfig, cgImage: CGImage, inputPath: String) -> Bool {
    if #available(macOS 15.0, *) {
        var resultJSON: [String: Any] = ["mode": "aesthetics", "file": inputPath]
        var resultText = ""

        var requestError: Error?
        var overallScore: Float = 0
        var isUtility: Bool = false
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let request = CalculateImageAestheticsScoresRequest()
                let observation = try await request.perform(on: cgImage)
                overallScore = observation.overallScore
                isUtility = observation.isUtility
            } catch {
                requestError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let error = requestError {
            fputs("ERROR: 美学评分失败: \(error.localizedDescription)\n", stderr)
            return false
        }

        resultJSON["overall_score"] = overallScore
        resultJSON["is_utility"] = isUtility
        resultText = "美学评分: \(String(format: "%.3f", overallScore))\n工具图: \(isUtility ? "是" : "否")"

        switch config.outputFormat {
        case "json":
            if let jsonData = try? JSONSerialization.data(withJSONObject: resultJSON, options: .prettyPrinted),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                if let outPath = config.outputDir {
                    try? jsonStr.write(toFile: outPath, atomically: true, encoding: .utf8)
                } else {
                    print(jsonStr)
                }
            }
        default:
            if let outPath = config.outputDir {
                try? resultText.write(toFile: outPath, atomically: true, encoding: .utf8)
            } else {
                print(resultText)
            }
        }
        return true
    } else {
        fputs("ERROR: 美学评分需要 macOS 15+\n", stderr)
        return false
    }
}

// MARK: - 合成工具

func compositeWithMask(cgImage: CGImage, mask: CVPixelBuffer) -> CGImage? {
    let originalCI = CIImage(cgImage: cgImage)
    let maskCI = CIImage(cvPixelBuffer: mask)

    // 将蒙版转为 alpha 通道
    let alphaFilter = CIFilter(name: "CIMaskToAlpha")!
    alphaFilter.setValue(maskCI, forKey: kCIInputImageKey)

    guard let alphaMask = alphaFilter.outputImage else { return nil }

    // 使用 CIBlendWithMask 合成
    guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
    blendFilter.setValue(originalCI, forKey: kCIInputImageKey)
    blendFilter.setValue(alphaMask, forKey: kCIInputMaskImageKey)
    blendFilter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)

    guard let result = blendFilter.outputImage else { return nil }

    let context = CIContext(options: [.useSoftwareRenderer: false])
    return context.createCGImage(result, from: originalCI.extent)
}

// MARK: - 批量处理

func getImagesInDirectory(_ dirPath: String) -> [String] {
    let extensions = ["jpg", "jpeg", "png", "tiff", "tif", "bmp", "heic", "heif", "webp"]
    guard let contents = FileManager.default.enumerator(atPath: dirPath) else { return [] }

    var images: [String] = []
    while let file = contents.nextObject() as? String {
        let ext = (file as NSString).pathExtension.lowercased()
        if extensions.contains(ext) {
            images.append((dirPath as NSString).appendingPathComponent(file))
        }
    }
    return images.sorted()
}

// MARK: - 处理单张图片

func processImage(_ inputPath: String, config: CVConfig) -> Bool {
    // 美学评分不需要加载 CGImage（内部处理）
    if config.mode == "aesthetics" {
        guard let cgImage = loadCGImage(from: inputPath) else { return false }
        return aestheticsScoring(config: config, cgImage: cgImage, inputPath: inputPath)
    }

    guard let cgImage = loadCGImage(from: inputPath) else {
        fputs("ERROR: 无法加载图片: \(inputPath)\n", stderr)
        return false
    }

    fputs("处理: \(inputPath) (\(cgImage.width)x\(cgImage.height), 模式: \(config.mode))\n", stderr)

    switch config.mode {
    case "person":
        return personSegmentation(config: config, cgImage: cgImage, inputPath: inputPath)
    case "foreground":
        return foregroundSegmentation(config: config, cgImage: cgImage, inputPath: inputPath)
    default:
        fputs("ERROR: 未知模式: \(config.mode)\n", stderr)
        return false
    }
}

// MARK: - 主入口

func main() {
    guard let config = parseArgs() else { exit(1) }

    // 批量模式
    if let batchDir = config.batchDir {
        let images = getImagesInDirectory(batchDir)
        guard !images.isEmpty else {
            fputs("ERROR: 目录中未找到图片: \(batchDir)\n", stderr)
            exit(1)
        }

        if let outDir = config.outputDir {
            ensureDirectory(outDir)
        }

        fputs("批量处理: \(images.count) 张图片\n", stderr)
        var successCount = 0
        let startTime = Date()

        for (i, imagePath) in images.enumerated() {
            fputs("[\(i + 1)/\(images.count)] ", stderr)
            if processImage(imagePath, config: config) {
                successCount += 1
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        fputs("\n完成: \(successCount)/\(images.count) 成功, 耗时 \(String(format: "%.1f", elapsed))s\n", stderr)
        exit(successCount > 0 ? 0 : 1)
    }

    // 单张模式
    if !processImage(config.inputPath, config: config) {
        exit(1)
    }
}

main()
