# macOS 原生 AI 基础服务工具集

基于 Apple 原生框架（Vision / Speech / AVFoundation）的命令行 AI 工具集，全程本地处理，零云端依赖。同时包含 QQ 群聊信息筛选脚本作为下游应用。

---

## 目录结构

```
~/Documents/qq/
├── ocr / ocr.swift            # OCR 工具 — Vision Framework
├── asr / asr.swift            # ASR 工具 — Speech Framework
├── tts / tts.swift            # TTS 工具 — AVFoundation
├── analyzer.py                # QQ 群聊 → Obsidian 笔记（LLM 语义分类）
├── run.sh                     # analyzer.py 启动脚本（conda 封装）
├── docs/
│   └── mac-ai-services-research.md   # 框架调研报告
├── models/
│   └── Qwen3-14B-4bit/       # MLX 4bit LLM（7.8GB）
└── README.md
```

---

## OCR 工具

基于 macOS Vision Framework 的文字识别工具。自动利用 Apple Silicon Neural Engine 加速。

### 快速开始

```bash
# 单张图片识别（纯文本输出）
./ocr photo.png

# 输出结构化 JSON（含坐标、置信度）
./ocr photo.png -f json

# 批量处理整个目录
./ocr -d ./images/ -f json -o results.json
```

### 完整参数

| 参数 | 缩写 | 说明 | 默认值 |
|------|------|------|--------|
| `--language <codes>` | `-l` | 识别语言，逗号分隔，按优先级排列。支持约 50 种语言，常用：`en-US`、`zh-Hans`（简中）、`zh-Hant`（繁中）、`ja-JP`、`ko-KR`、`fr-FR`、`de-DE`、`es-ES`、`ru-RU` 等 | `zh-Hans,zh-Hant,en-US` |
| `--mode <level>` | `-m` | 识别模式。`fast` 速度优先（~50-150ms/图），适合实时预览；`accurate` 精度优先（~100-400ms/图），适合文档处理、CJK 文字、手写体 | `accurate` |
| `--format <fmt>` | `-f` | 输出格式。`txt` 纯文本每行一个区域；`json` 结构化输出含 text/confidence/boundingBox(x,y,width,height) | `txt` |
| `--dir <path>` | `-d` | 批量处理模式下指定图片目录。递归扫描所有 png/jpg/jpeg/tiff/bmp/heic/webp 文件 | 无（单文件模式） |
| `--output <path>` | `-o` | 输出到文件。批量模式下 JSON 格式合并所有结果，TXT 格式用 `=== 文件名 ===` 分隔 | stdout |
| `--min-text-height <float>` | — | 最小文字高度，归一化值 0.0-1.0。用于过滤图片中的小文字（如水印、噪点），设为 0 不限制 | `0` |
| `--no-language-correction` | — | 禁用语言模型矫正。通常不建议禁用，除非需要原始识别结果 | 启用 |
| `--auto-detect-language` | — | 自动检测图片中的语言（需 macOS 13+，Revision 3）。与 `--language` 互斥，同时指定时两者均生效 | 关闭 |
| `--help` | `-h` | 显示帮助信息 | — |

### 输出格式示例

**txt 格式**（直接输出识别到的文本行）：

```
Hello World
你好世界
第三行文字
```

**json 格式**（结构化数据，含坐标和置信度）：

```json
{
  "file": "photo.png",
  "texts": [
    {
      "text": "Hello World",
      "confidence": 0.9876,
      "boundingBox": { "x": 0.05, "y": 0.58, "width": 0.14, "height": 0.1 }
    }
  ]
}
```

坐标为归一化值（0.0-1.0），原点在图片左下角。批量模式输出为 JSON 数组。

### 使用场景

```bash
# 中英混排文档
./ocr document.png -l zh-Hans,en-US -m accurate -f txt

# 日文图片
./ocr japanese.png -l ja-JP,en-US

# 只要大文字（过滤小字注释）
./ocr slide.png --min-text-height 0.02

# 快速预览模式（牺牲精度换速度）
./ocr screenshot.png -m fast

# 批量提取并保存
./ocr -d ./screenshots/ -f json -o all_text.json
```

---

## ASR 工具

基于 macOS Speech Framework 的语音识别工具。支持文件转写和设备端离线识别。

### 快速开始

```bash
# 识别音频文件
./asr recording.wav

# 生成 SRT 字幕文件
./asr meeting.m4a -l en-US --punctuation -f srt -o meeting.srt

# 离线设备端识别
./asr voice.wav --on-device
```

### 完整参数

| 参数 | 缩写 | 说明 | 默认值 |
|------|------|------|--------|
| `--locale <code>` | `-l` | 识别语言区域。支持 70+ 语言区域，常用：`en-US`、`zh-CN`、`zh-TW`、`ja-JP`、`ko-KR`、`fr-FR`、`de-DE` 等。运行时可通过 `SFSpeechRecognizer.supportedLocales()` 查询完整列表 | `zh-CN` |
| `--on-device` | — | 强制使用设备端识别。音频不上传至 Apple 服务器，完全离线处理。需要对应语言模型已下载（系统设置 → 辅助功能 → 语音内容 → 语言）。若该语言不支持设备端识别会报错退出 | 关闭（使用服务端） |
| `--task-hint <type>` | — | 任务类型提示，帮助识别器优化模型。`dictation` 通用听写/长文本；`search` 短搜索关键词；`confirmation` 短确认词（是/否等） | `dictation` |
| `--punctuation` | — | 自动添加标点符号（需 macOS 12+）。识别结果会自动插入逗号、句号、问号等 | 关闭 |
| `--contextual <words>` | — | 领域特定词汇，逗号分隔。提升专有名词、人名、术语的识别准确率。例：`--contextual "QoderWork,macOS,WWDC"` | 无 |
| `--format <fmt>` | `-f` | 输出格式。`txt` 纯文本；`srt` 带时间戳的 SRT 字幕格式（自动按停顿和标点分段） | `txt` |
| `--output <path>` | `-o` | 输出到文件 | stdout |
| `--help` | `-h` | 显示帮助信息 | — |

### 支持的音频格式

| 格式 | 扩展名 | 说明 |
|------|--------|------|
| WAV | `.wav` | 无压缩，兼容性最佳 |
| AIFF | `.aiff` | Apple 原生无压缩 |
| AAC | `.m4a` / `.aac` | 压缩，质量/体积比好 |
| MP3 | `.mp3` | 压缩，通用格式 |
| CAF | `.caf` | Core Audio 格式 |

推荐参数：16kHz 采样率、16bit、单声道。

### 设备端 vs 服务端

| 对比 | 设备端 (`--on-device`) | 服务端（默认） |
|------|----------------------|--------------|
| 隐私 | 音频不离开本机 | 音频发送至 Apple 服务器 |
| 精度 | 良好（较小模型） | 最佳（云端大模型） |
| 网络 | 不需要 | 需要联网 |
| 速率限制 | 无 | 约 1000 次/小时 |
| 音频长度 | 受内存限制，可处理较长音频 | 约 1 分钟/次 |
| 语言支持 | 部分语言 | 全部支持 |

### SRT 输出示例

```srt
1
00:00:00,000 --> 00:00:03,500
大家好，欢迎参加今天的会议。

2
00:00:04,000 --> 00:00:07,200
今天我们讨论一下新项目的进展。

3
00:00:08,100 --> 00:00:12,000
第一个议题是关于产品上线时间的确认。
```

SRT 格式自动按标点符号（。？！，. ? !）和语音停顿（>0.5s）分段，每段带时间戳。

### 使用场景

```bash
# 中文会议录音转文字
./asr meeting.wav -l zh-CN --punctuation

# 英文播客生成字幕
./asr podcast.m4a -l en-US --punctuation -f srt -o podcast.srt

# 离线模式（隐私敏感场景）
./asr confidential.wav --on-device -l zh-CN

# 医学领域词汇偏置
./asr lecture.wav -l zh-CN --contextual "神经内科,脑电图,癫痫,帕金森"

# 短语音命令识别
./asr command.wav --task-hint confirmation
```

### 权限说明

首次运行会弹出系统授权请求（系统偏好设置 → 隐私与安全 → 语音识别）。设备端识别需先在系统设置中下载对应语言模型。

---

## TTS 工具

基于 macOS AVFoundation 的语音合成工具。支持系统全部音色，可输出音频文件。

### 快速开始

```bash
# 直接朗读
./tts "Hello, world!"

# 中文朗读
./tts "你好世界" -v zh-CN

# 输出音频文件
./tts "Hello" -v Samantha -o hello.aiff

# 查看所有中文音色
./tts --list-voices zh
```

### 完整参数

| 参数 | 缩写 | 说明 | 默认值 |
|------|------|------|--------|
| `<text>` | — | 要朗读的文本（位置参数，支持多词拼接） | 必填（或 `-f` 指定文件） |
| `--voice <name\|lang>` | `-v` | 音色选择。可以是音色名称（如 `Samantha`、`Tingting`）或语言代码（如 `zh-CN`、`en-US`）。匹配优先级：精确名称 > 模糊名称 > 语言代码 > 语言前缀。使用 `--list-voices` 查看所有可用音色 | 系统默认 |
| `--rate <float>` | `-r` | 语速，范围 0.0-1.0。0.0 最慢，0.5 正常语速，1.0 最快 | `0.5` |
| `--pitch <float>` | `-p` | 音调，范围 0.5-2.0。0.5 低沉，1.0 正常，2.0 尖锐 | `1.0` |
| `--volume <float>` | — | 音量，范围 0.0-1.0。0.0 静音，1.0 最大 | `1.0` |
| `--pre-delay <seconds>` | — | 朗读前延迟秒数 | `0` |
| `--post-delay <seconds>` | — | 朗读后延迟秒数 | `0` |
| `--file <path>` | `-f` | 从文件读取文本内容（UTF-8 编码） | 无 |
| `--output <path>` | `-o` | 输出音频文件。实际输出为 AIFF 格式（若指定非 .aiff 扩展名会自动转换并提示）。如需 WAV 格式可用系统 `say` 命令或 ffmpeg 转换 | 直接播放 |
| `--list-voices [filter]` | — | 列出所有可用音色。可跟过滤关键词（如 `zh`、`en`、`Samantha`），显示名称、语言、质量、性别、标识符 | — |
| `--help` | `-h` | 显示帮助信息 | — |

### 系统音色

音色质量分三个等级：

| 等级 | 说明 | 获取方式 |
|------|------|---------|
| 标准（default） | 内置，体积小 | 系统自带 |
| 增强（enhanced） | 高质量 | 系统设置 → 辅助功能 → 语音内容 → 系统语音 → 管理语音 |
| 高级（premium） | 最高质量，最自然 | 同上（macOS 13+） |

常用中文音色：Tingting（zh-CN，女声）、Meijia（zh-TW，女声）。系统还内置多种特色音色（Eddy、Flo、Grandma、Grandpa 等）。

### 使用场景

```bash
# 慢速朗读英文文章
./tts -f article.txt -v en-US -r 0.3

# 生成中文语音文件
./tts "今天天气不错" -v Tingting -o weather.aiff

# 低音调朗读
./tts "Deep voice test" -v Alex -p 0.7

# 查看所有可用音色
./tts --list-voices

# 只看女声音色
./tts --list-voices | grep 女
```

### 文件输出说明

TTS 文件输出使用 `NSSpeechSynthesizer`（所有 macOS 版本均支持），输出格式为 AIFF。如需 WAV 格式，可用以下方式转换：

```bash
# 使用系统 say 命令直接输出 WAV
say -o output.wav --file-format WAVE --data-format LEI16 "Hello"

# 使用 ffmpeg 从 AIFF 转 WAV
ffmpeg -i output.aiff output.wav
```

---

## 编译说明

所有工具使用 Swift 编写，调用 macOS 原生框架，零外部依赖。

```bash
# OCR（Vision Framework）
swiftc -O -framework Cocoa -framework Vision ocr.swift -o ocr

# ASR（Speech Framework）
swiftc -O -framework Speech -framework AVFoundation asr.swift -o asr

# TTS（AVFoundation）
swiftc -O -framework AVFoundation -framework Cocoa tts.swift -o tts
```

要求：macOS 10.15+（Catalina），Xcode Command Line Tools（`xcode-select --install`）。ASR 的设备端识别需 macOS 13+ 以获得完整语言支持。

---

## 隐私与安全

| 工具 | 联网情况 | 说明 |
|------|---------|------|
| OCR | 不联网 | Vision Framework 完全本地处理 |
| ASR（默认） | 联网 | 音频发送至 Apple 服务器处理 |
| ASR（`--on-device`） | 不联网 | 设备端模型，完全本地 |
| TTS | 不联网 | AVFoundation 完全本地处理 |
| LLM | 不联网 | MLX 本地推理，`HF_HUB_OFFLINE=1` |
