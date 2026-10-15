# LOOI DF26 · iOS

<p align="center">
  <img src="docs/assets/app-icon-rounded.svg" alt="LOOI iOS App icon" width="128" height="128">
</p>

<p align="center">
  <a href="#简体中文">简体中文</a> · <a href="#english">English</a>
</p>

## 简体中文

LOOI 桌面陪伴机器人的独立 iOS 客户端。使用 SwiftUI 原生界面、AVFoundation 音视频和 Core Bluetooth 连接机器人，保留原始眼睛动画与动作编排。

### 功能

- **竖屏设置、横屏陪伴**：竖屏配置 AI 和机器人；开始陪伴后请求横屏显示眼睛。轻点横屏画面显示“退出陪伴”，退出后返回竖屏。
- **实时语音与视觉**：Gemini / Vertex Live，通过原生 WebSocket 持续收发音频，并按需发送摄像头画面；横屏保留实时摄像头预览小窗。
- **连续语音播放**：分段缓冲、短时预缓冲、播放停滞检测和有限次数的自动恢复。
- **机器人列表**：显示附近设备的名称、标识后缀和信号强度，支持本地别名、“我的机器人”标记、点头识别和动作测试。
- **模型配置**：Gemini、Vertex AI、通义千问、Groq、Fireworks、Ollama 和兼容接口，提供默认模型，也允许自定义。实时语音仅适用于支持 Live 的提供商；其他接口使用文字 / 视觉模式。
- **安全存储**：用户自行填写 API Key，凭据存入 iOS 钥匙串。运动需要连接机器人并明确开启许可。

界面目前主要为简体中文；本 README 同时提供中英文。

### 环境与快速开始

- macOS、Xcode 和 iOS SDK；当前副本已使用 Xcode 27 完成无签名设备编译。
- 部署目标 iOS 15+；主动请求横竖屏使用 iOS 16+ API，iOS 15 可能需要手动转动手机。
- 实时音视频、蓝牙连接和自动旋转效果请使用真机验证。

```sh
git clone https://github.com/xlle-er/LOOI-DF26-IOS.git
cd LOOI-DF26-IOS
open LOOI.xcodeproj
```

1. 等待 Xcode 解析 GoogleSignIn 的 Swift Package 依赖，选择 **LOOI** scheme。
2. 设置自己的签名和 Bundle Identifier。推荐复制本地配置模板：

   ```sh
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
   ```

   编辑该文件，填入自己的 `DEVELOPMENT_TEAM` 和唯一 `PRODUCT_BUNDLE_IDENTIFIER`。该本地文件已被 Git 忽略。也可在 Xcode 的 Signing & Capabilities 中配置自己的 Team，但不要把个人签名改动提交到仓库。
3. 选择自己的 iPhone，编译运行，并授予需要的相机、麦克风和蓝牙权限。
4. 在 App 的 **AI 服务** 中选择提供商、模型并填写自己的凭据，先测试声音和 AI，再开始陪伴。无硬件时可不连接机器人。

**无需 Node.js、Capacitor、网页服务器或后端即可从 Xcode 构建。** 眼睛资源与 Live 配置已包含在 Swift Package 内。原始网页、Android、固件构建产物和个人设备配置未复制到此仓库。

### 模型和账号

预设模型只是便捷默认值，不保证每个地区、账号或套餐都可使用；可根据提供商的模型列表修改名称。Vertex 标准项目需填写自己的项目 ID、区域和认证信息。Ollama 需先在局域网电脑上安装模型并允许手机访问其服务。

Google OAuth 为可选功能。需要时请自行注册 iOS OAuth 客户端、设置 `App/Info.plist` 中的 `GIDClientID`，并添加匹配的反向客户端 ID URL Scheme；默认没有内置 OAuth 身份。使用 API Key 时无需该配置。

API Key 不包含在仓库中。运行时机器人别名、选中设备、历史连接记录和模型配置由每位用户保存在自己的设备上。

### 开发与验证

仅修改 Swift 代码时直接在 Xcode 构建即可。修改眼睛 / 动作 JavaScript、样式或 Live 提示词后：

```sh
npm ci
npm run build:resources
```

可选检查：

```sh
python3 scripts/test-native.py       # 原生协议、请求、缓冲和配置检查
python3 scripts/check-privacy.py     # 提交文件的隐私检查（只输出位置，不输出敏感值）
npx playwright install chromium
npm run test:face                   # 眼睛布局和动作桥接检查
xcodebuild -project LOOI.xcodeproj -scheme LOOI \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

若已安装 Google Chrome，可用 `PLAYWRIGHT_CHANNEL=chrome npm run test:face`，无需下载 Chromium。

自动检查不代表已验证真机扬声器、相机、蓝牙和所有系统音频中断场景。

### 目录与来源

| 目录 | 内容 |
| --- | --- |
| `LOOI.xcodeproj`, `App/` | Xcode 工程、UIKit 启动入口、资源和权限声明 |
| `Native/` | Swift Package；原生 UI、AI、音视频、蓝牙和打包后的眼睛资源 |
| `FaceSource/` | 原始眼睛动画、动作编排及其最小依赖，可重新构建 |
| `Config/` | 可提交的配置与个人签名配置模板 |
| `Tests/`, `scripts/` | 原生检查、眼睛检查、资源构建和隐私检查 |
| `docs/architecture.md` | 架构、媒体生命周期、蓝牙协议及限制 |

本项目从 [LOOI_DF26](https://github.com/xlle-er/LOOI_DF26) 的 iOS 实现整理而来，保留原有眼睛动画和小车动作代码。此副本使用全新 Git 历史，不包含原仓库历史、设备 UDID、个人开发团队、证书、密钥、照片或本机构建缓存。来源与依赖说明见 [NOTICE.md](NOTICE.md)。

## English

An independent iOS client for the LOOI desktop companion robot. It uses native SwiftUI, AVFoundation and Core Bluetooth while retaining the original eye animations and motion choreography.

### Features

- **Portrait setup, landscape companion:** configure AI and robots in portrait; starting companionship requests landscape for the eyes. Tap to reveal **退出陪伴** (Exit companion); exiting restores portrait setup.
- **Live voice and vision:** native Gemini / Vertex Live WebSocket sessions with continuous audio and optional camera frames. A small live camera preview stays visible in landscape.
- **Streaming playback:** sliced audio buffering, a short startup buffer, stall detection and bounded automatic recovery.
- **Nearby robot list:** names, identifier suffixes, signal strength, local aliases, ownership bookmarks, identification nods and motion tests.
- **Provider presets:** Gemini, Vertex AI, Qwen, Groq, Fireworks, Ollama and compatible endpoints, with editable model defaults. Live speech requires a supported Live provider; other providers use text / vision requests.
- **Local credentials:** enter your own API key; credentials are stored in the iOS Keychain. Physical movement requires a connected robot and explicit permission.

The app UI is currently primarily Simplified Chinese. This README is bilingual.

### Requirements and setup

- macOS with Xcode and the iOS SDK. This extraction was compiled unsigned using Xcode 27.
- Deployment target: iOS 15+. Programmatic orientation requests use iOS 16+ APIs; iOS 15 may require physically rotating the phone.
- Use a real iPhone to verify audio, camera, Bluetooth and orientation behavior.

```sh
git clone https://github.com/xlle-er/LOOI-DF26-IOS.git
cd LOOI-DF26-IOS
open LOOI.xcodeproj
```

1. Allow Xcode to resolve the GoogleSignIn Swift Package dependencies and select the **LOOI** scheme.
2. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`. Set your own `DEVELOPMENT_TEAM` and unique `PRODUCT_BUNDLE_IDENTIFIER`. This local file is ignored by Git. Alternatively configure your own Team in Xcode's Signing & Capabilities, keeping personal signing edits out of commits.
3. Select your iPhone, build and run, then grant the required camera, microphone and Bluetooth permissions.
4. Open **AI 服务** (AI services), select a provider and model, enter your own credentials, and test sound and AI before starting. A robot is optional.

**Building in Xcode does not require Node.js, Capacitor, a web server or a backend.** Eye resources and Live configuration are already packaged. This repository excludes the full website, Android application, firmware build artifacts and personal device configuration.

### Models and credentials

Preset model names are conveniences, not guarantees of availability for every region, account or plan. Change the name to a model available to your provider account. Vertex standard projects require your own project ID, region and authentication. Ollama requires installing a model on a LAN computer and making that service reachable from the phone.

Google OAuth is optional. To use it, register your own iOS OAuth client, set `GIDClientID` in `App/Info.plist`, and add the matching reversed-client-ID URL scheme. No OAuth identity is bundled. API-key authentication does not need this setup.

No API keys are included. Robot aliases, selected devices, connection history and model settings are created locally on each user's device.

### Development and checks

Swift-only edits can be built directly in Xcode. After editing eye / motion JavaScript, styles or the Live system instruction:

```sh
npm ci
npm run build:resources
```

Optional checks:

```sh
python3 scripts/test-native.py
python3 scripts/check-privacy.py
npx playwright install chromium
npm run test:face
xcodebuild -project LOOI.xcodeproj -scheme LOOI \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

If Google Chrome is installed, use `PLAYWRIGHT_CHANNEL=chrome npm run test:face` to avoid downloading Chromium.

The automated checks cover native protocol/request/buffering/configuration behavior and eye layout/command bridging. They do not verify physical speaker output, camera capture, Bluetooth hardware or every OS interruption.

### Layout and provenance

- `App/` and `LOOI.xcodeproj`: application entry points, assets and permissions.
- `Native/`: Swift Package containing native UI, AI, media, Bluetooth and bundled eye resources.
- `FaceSource/`: editable original eye/motion sources and their minimal dependencies.
- `Config/`: shared configuration and the local signing template.
- `Tests/` and `scripts/`: checks, resource generation and privacy scanning.
- [`docs/architecture.md`](docs/architecture.md): implementation details, media lifecycle and Bluetooth protocol.

Extracted from the iOS implementation in [LOOI_DF26](https://github.com/xlle-er/LOOI_DF26), retaining original eye animations and robot motion code. This copy starts with fresh Git history and excludes the original history, device UDIDs, personal signing teams, certificates, keys, photos and local build caches. See [NOTICE.md](NOTICE.md) for provenance and dependency notices.
