# macai

![macOS](https://img.shields.io/badge/macOS-10.15+-blue?logo=apple)
![License](https://img.shields.io/badge/license-MIT-green)
![Swift](https://img.shields.io/badge/Swift-5.0+-orange?logo=swift)

macOS 原生 AI 基础服务命令行工具集。基于 Apple 原生框架（Vision / Speech / AVFoundation），全程本地处理，零云端依赖，Apple Silicon Neural Engine 加速。

| 工具 | 功能 | 框架 | 联网 |
|------|------|------|------|
| `ocr` | 文字识别 | Vision | 不联网 |
| `asr` | 语音识别 | Speech | 默认联网，`--on-device` 离线 |
| `tts` | 语音合成 | AVFoundation | 不联网 |

---

## 安装

### 方式 1：下载预编译二进制（推荐）

从 [Releases](https://github.com/Eli-Zxh/macai/releases) 页面下载对应二进制文件：

```bash
# 下载（以 v1.0.0 为例）
curl -LO https://github.com/Eli-Zxh/macai/releases/download/v1.0.0/ocr
curl -LO https://github.com/Eli-Zxh/macai/releases/download/v1.0.0/asr
curl -LO https://github.com/Eli-Zxh/macai/releases/download/v1.0.0/tts

# 赋予执行权限
chmod +x ocr asr tts

# 验证
./ocr --help
./asr --help
./tts --help
```

### 方式 2：从源码编译

需要 macOS 10.15+（Catalina）和 Xcode Command Line Tools。

```bash
# 安装 Xcode Command Line Tools（如尚未安装）
xcode-select --install

# 克隆仓库
git clone https://github.com/Eli-Zxh/macai.git
cd macai

# 一键编译全部
make all

# 或单独编译某个工具
make ocr
make asr
make tts
```

### 方式 3：Homebrew（计划中）

```bash
# 待发布，目前请先使用方式 1 或 2
# brew install Eli-Zxh/macai/macai
```

---

## 快速开始

```bash
# OCR：识别图片中的文字
./ocr photo.png

# OCR：输出结构化 JSON（含坐标、置信度）
./ocr photo.png -f json

# ASR：转录音频文件
./asr recording.wav -l en-US

# ASR：生成 SRT 字幕
./asr meeting.m4a -l zh-CN --punctuation -f srt -o meeting.srt

# TTS：朗读文本
./tts "Hello, world!"

# TTS：生成音频文件
./tts "你好世界" -v zh-CN -o hello.aiff
```

---

## OCR 工具

基于 macOS Vision Framework 的文字识别。自动利用 Apple Silicon Neural Engine 加速，支持约 50 种语言。

### 参数

| 参数 | 缩写 | 说明 | 默认值 |
|------|------|------|--------|
| `--language <codes>` | `-l` | 识别语言，逗号分隔，按优先级排列。常用：`en-US`、`zh-Hans`（简中）、`zh-Hant`（繁中）、`ja-JP`、`ko-KR`、`fr-FR`、`de-DE` 等 | `zh-Hans,zh-Hant,en-US` |
| `--mode <level>` | `-m` | `fast` 速度优先（~50-150ms/图）；`accurate` 精度优先（~100-400ms/图），适合文档、CJK、手写体 | `accurate` |
| `--format <fmt>` | `-f` | `txt` 纯文本；`json` 含 text/confidence/boundingBox | `txt` |
| `--dir <path>` | `-d` | 批量处理目录，递归扫描 png/jpg/jpeg/tiff/bmp/heic/webp | 无（单文件模式） |
| `--output <path>` | `-o` | 输出到文件。批量 JSON 合并为数组，TXT 用 `=== 文件名 ===` 分隔 | stdout |
| `--min-text-height <float>` | — | 最小文字高度 0.0-1.0，过滤水印/噪点 | `0` |
| `--no-language-correction` | — | 禁用语言模型矫正 | 启用 |
| `--auto-detect-language` | — | 自动检测语言（macOS 13+） | 关闭 |
| `--help` | `-h` | 显示帮助 | — |

### 输出示例

**txt 格式** — 对以下图片运行 `./ocr test.png -l en-US`：

```
The Quick Brown Fox
jumps over the lazy dog.
Pack my box with five dozen liquor jugs.
How vexingly quick daft zebras jump!
The five boxing wizards jump quickly.
Sphinx of black quartz, judge my vow.
1234567890 @#$%&*() 2026-07-08
```

**json 格式** — 同一图片运行 `./ocr test.png -l en-US -f json`：

```json
{
  "file": "test.png",
  "texts": [
    {
      "text": "The Quick Brown Fox",
      "confidence": 1.0,
      "boundingBox": { "x": 0.05, "y": 0.86, "width": 0.34, "height": 0.06 }
    },
    {
      "text": "jumps over the lazy dog.",
      "confidence": 1.0,
      "boundingBox": { "x": 0.045, "y": 0.725, "width": 0.3925, "height": 0.07 }
    }
  ]
}
```

坐标为归一化值（0.0-1.0），原点在图片**左下角**。`x`/`y` 为 bounding box 左下角坐标，`width`/`height` 为归一化尺寸。批量模式输出为 JSON 数组。

### 场景示例

```bash
# 中英混排文档
./ocr document.png -l zh-Hans,en-US

# 日文图片
./ocr japanese.png -l ja-JP,en-US

# 过滤小字注释/水印
./ocr slide.png --min-text-height 0.02

# 快速预览（牺牲精度换速度）
./ocr screenshot.png -m fast

# 批量提取整个目录，保存为 JSON
./ocr -d ./screenshots/ -f json -o all_text.json
```

---

## ASR 工具

基于 macOS Speech Framework 的语音识别。支持文件转写、设备端离线识别、自动标点。

### 参数

| 参数 | 缩写 | 说明 | 默认值 |
|------|------|------|--------|
| `--locale <code>` | `-l` | 识别语言区域，支持 70+。常用：`en-US`、`zh-CN`、`zh-TW`、`ja-JP`、`ko-KR`、`fr-FR` 等 | `zh-CN` |
| `--on-device` | — | 强制设备端识别，音频不上传。需先下载语言模型（系统设置 → 辅助功能 → 语音内容 → 语言） | 关闭（服务端） |
| `--task-hint <type>` | — | `dictation` 通用听写；`search` 短搜索词；`confirmation` 短确认词 | `dictation` |
| `--punctuation` | — | 自动添加标点（macOS 12+） | 关闭 |
| `--contextual <words>` | — | 领域词汇偏置，逗号分隔，提升专有名词识别率 | 无 |
| `--format <fmt>` | `-f` | `txt` 纯文本；`srt` 带时间戳字幕 | `txt` |
| `--output <path>` | `-o` | 输出到文件 | stdout |
| `--help` | `-h` | 显示帮助 | — |

**支持的音频格式**：WAV、AIFF、AAC/M4A、MP3、CAF。推荐 16kHz/16bit/单声道。

### 设备端 vs 服务端

| | 设备端 (`--on-device`) | 服务端（默认） |
|---|---|---|
| 隐私 | 音频不离开本机 | 音频发送至 Apple 服务器 |
| 精度 | 良好 | 最佳 |
| 网络 | 不需要 | 需要 |
| 速率限制 | 无 | ~1000 次/小时 |
| 音频长度 | 可处理较长音频 | ~1 分钟/次 |

### 输出示例

**txt 格式** — `./asr meeting.wav -l zh-CN --punctuation`：

```
大家好，欢迎参加今天的会议。今天我们讨论一下新项目的进展情况。第一个议题是关于产品上线时间的确认。
```

**srt 格式** — `./asr meeting.wav -l zh-CN --punctuation -f srt`：

```srt
1
00:00:00,000 --> 00:00:03,500
大家好，欢迎参加今天的会议。

2
00:00:04,000 --> 00:00:07,200
今天我们讨论一下新项目的进展情况。

3
00:00:08,100 --> 00:00:12,000
第一个议题是关于产品上线时间的确认。
```

SRT 格式自动按标点（。？！，. ? !）和语音停顿（>0.5s）分段。

### 场景示例

```bash
# 中文会议录音转文字
./asr meeting.wav -l zh-CN --punctuation

# 英文播客生成字幕
./asr podcast.m4a -l en-US --punctuation -f srt -o podcast.srt

# 完全离线（隐私敏感场景）
./asr confidential.wav --on-device -l zh-CN

# 医学领域词汇偏置
./asr lecture.wav -l zh-CN --contextual "神经内科,脑电图,癫痫,帕金森"

# 短语音命令识别
./asr command.wav --task-hint confirmation
```

### 首次使用

ASR 首次运行会弹出系统授权请求。请在 **系统设置 → 隐私与安全 → 语音识别** 中授权。如果是从终端运行被拦截，可能需要在 **系统设置 → 隐私与安全 → 安全性** 中允许该二进制运行。

---

## TTS 工具

基于 macOS AVFoundation 的语音合成。支持系统全部音色（含增强/高级），可输出音频文件。

### 参数

| 参数 | 缩写 | 说明 | 默认值 |
|------|------|------|--------|
| `<text>` | — | 要朗读的文本（位置参数） | 必填（或 `-f`） |
| `--voice <name\|lang>` | `-v` | 音色名称（如 `Samantha`、`Tingting`）或语言代码（如 `zh-CN`）。匹配优先级：精确名称 > 模糊名称 > 语言代码 | 系统默认 |
| `--rate <float>` | `-r` | 语速 0.0-1.0 | `0.5` |
| `--pitch <float>` | `-p` | 音调 0.5-2.0 | `1.0` |
| `--volume <float>` | — | 音量 0.0-1.0 | `1.0` |
| `--pre-delay <sec>` | — | 朗读前延迟秒数 | `0` |
| `--post-delay <sec>` | — | 朗读后延迟秒数 | `0` |
| `--file <path>` | `-f` | 从文件读取文本（UTF-8） | 无 |
| `--output <path>` | `-o` | 输出音频文件（AIFF 格式） | 直接播放 |
| `--list-voices [filter]` | — | 列出可用音色，可跟过滤关键词 | — |
| `--help` | `-h` | 显示帮助 | — |

### 音色

| 等级 | 说明 | 获取方式 |
|------|------|---------|
| 标准 | 内置，体积小 | 系统自带 |
| 增强 | 高质量 | 系统设置 → 辅助功能 → 语音内容 → 系统语音 → 管理语音 |
| 高级 | 最高质量 | 同上（macOS 13+） |

常用中文音色：Tingting（zh-CN，女声）、Meijia（zh-TW，女声）。系统还内置 Eddy、Flo、Grandma、Grandpa 等特色音色。

### 输出示例

```bash
# 列出所有中文音色
$ ./tts --list-voices zh

名称                             语言       质量     性别   标识符
------------------------------------------------------------------------------------------
Tingting                         zh-CN      标准       女      com.apple.voice.compact.zh-CN.Tingting
Meijia                           zh-TW      标准       女      com.apple.voice.super-compact.zh-TW.Meijia
...
共 19 个音色
```

```bash
# 英文朗读
$ ./tts "Hello, this is a test." -v en-US

# 中文朗读并保存
$ ./tts "你好，这是语音合成测试。" -v zh-CN -o test.aiff
已写入: test.aiff

# 从文件读取，慢速朗读
$ ./tts -f article.txt -r 0.3 -v en-US

# 低音调效果
$ ./tts "Deep voice test" -p 0.7
```

### 文件格式

TTS 文件输出为 **AIFF** 格式。如需 WAV：

```bash
# 方法 1：用系统 say 命令直接输出 WAV
say -o output.wav --file-format WAVE --data-format LEI16 "Hello"

# 方法 2：用 ffmpeg 转换
ffmpeg -i output.aiff output.wav

# 方法 3：用 macOS 自带 afconvert
afconvert output.aiff output.wav -d LEI16 -f WAVE
```

---

## 工具组合使用

三个工具可以串联成完整的工作流：

### 批量截图文字提取

```bash
# 提取所有截图中的文字，保存为 JSON
./ocr -d ./screenshots/ -l zh-Hans,en-US -f json -o extracted.json

# 或用管道逐张处理
for img in ./screenshots/*.png; do
    echo "=== $(basename $img) ==="
    ./ocr "$img" -l zh-Hans,en-US
    echo ""
done > all_text.txt
```

### 音频转写 + 字幕生成

```bash
# 会议录音 → SRT 字幕
./asr meeting.m4a -l zh-CN --punctuation -f srt -o meeting.srt

# 英文播客 → 纯文本
./asr podcast.mp3 -l en-US --punctuation -o podcast.txt
```

### TTS 生成有声读物

```bash
# 从文本文件生成语音
./tts -f chapter1.txt -v Tingting -r 0.4 -o chapter1.aiff

# 批量转换
for txt in chapters/*.txt; do
    name=$(basename "$txt" .txt)
    ./tts -f "$txt" -v Tingting -r 0.4 -o "audio/${name}.aiff"
done
```

### OCR → TTS 朗读图片内容

```bash
# 识别图片文字并朗读
./ocr photo.png -l en-US | ./tts -f /dev/stdin -v en-US

# 识别中文图片并朗读
./ocr document.png -l zh-Hans | ./tts -f /dev/stdin -v zh-CN
```

---

## 常见问题

### Q: 运行 OCR/ASR/TTS 时报 "无法打开，因为无法验证开发者"

macOS Gatekeeper 会拦截从网上下载的二进制。解决方法：

```bash
# 方法 1：移除隔离属性
xattr -d com.apple.quarantine ocr asr tts

# 方法 2：在 系统设置 → 隐私与安全 → 安全性 中点击"仍要打开"
```

### Q: ASR 报错 "语音识别未授权"

ASR 需要系统授权。首次运行请在 **终端.app** 中执行（非 IDE 内部终端），系统会弹出授权对话框。前往 **系统设置 → 隐私与安全 → 语音识别** 确认已授权。

### Q: ASR 报错 "不支持设备端识别"

`--on-device` 需要先下载语言模型。前往 **系统设置 → 辅助功能 → 语音内容 → 语言**，下载目标语言的模型后重试。

### Q: TTS 输出没有声音 / 音色找不到

增强/高级音色需要手动下载。前往 **系统设置 → 辅助功能 → 语音内容 → 系统语音 → 管理语音**，搜索并下载需要的音色。

### Q: OCR 识别率低

- 确认 `--language` 包含了图片中的语言
- 使用 `-m accurate`（默认）而非 `fast`
- 图片分辨率建议 300 DPI 以上
- 如果文字很小，尝试 `--min-text-height 0`（确保没有过滤掉）

### Q: 支持哪些 macOS 版本？

| 功能 | 最低版本 |
|------|---------|
| OCR 基础 | macOS 10.15 |
| OCR 手写识别 | macOS 11.0 |
| OCR 自动语言检测 | macOS 13.0 |
| ASR 基础 | macOS 10.15 |
| ASR 自动标点 | macOS 12.0 |
| TTS 基础 | macOS 10.14 |
| TTS 高级音色 | macOS 13.0 |

---

## 隐私

| 工具 | 联网 | 说明 |
|------|------|------|
| OCR | 不联网 | Vision Framework 完全本地处理 |
| ASR（默认） | 联网 | 音频发送至 Apple 服务器 |
| ASR（`--on-device`） | 不联网 | 设备端模型，完全本地 |
| TTS | 不联网 | AVFoundation 完全本地处理 |

---

## 许可证

[MIT License](LICENSE)
