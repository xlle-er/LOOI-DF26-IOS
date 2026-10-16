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
- **手动遥控**：摇杆与方向键切换，支持独立遥控及陪伴中遥控，按住运动、松手停止。手动控制暂停 AI 身体动作；独立遥控不启动 AI 或相机。
- **机器人列表**：显示附近设备的名称、标识后缀和信号强度，支持本地别名、“我的机器人”标记、设备信息核对和动作测试。
- **模型配置**：Gemini、Vertex AI、通义千问、Groq、Fireworks、Ollama 和兼容接口，提供默认模型，也允许自定义。实时语音仅适用于支持 Live 的提供商；其他接口使用文字 / 视觉模式。
- **安全存储**：用户自行填写 API Key，凭据存入 iOS 钥匙串。每次开始陪伴默认开启身体运动，仍需连接机器人；陪伴页可关闭或重新开启。停止、断连、故障和手动遥控会撤销本次许可。

界面支持简体中文和 English，在“AI 服务 → 界面语言”中选择跟随系统、简体中文或 English。状态与错误提示会同步切换；iOS 系统权限弹窗遵循系统 / 单独 App 语言设置。

AI 优先使用用户明确要求的语言，否则跟随用户最新输入或说话的语言，支持对话中途换语言。只有没有明确语言线索时，才使用界面语言。语言设置不会强制把语音回复固定为中文或英文。离线模式提供中英文固定问候，不等同于多语言 AI 模型。

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

### 遥控器

连接自己的机器人后，在设置页打开“遥控器”，或在横屏陪伴的控制浮层打开。支持摇杆 / 方向键、相对速度调节和停止按钮。初始速度值为 0.15，可调 0.05～0.30；它是控制量，不代表米每秒或准确的电机占空比。急停后必须松手再重新操作。关闭遥控后，AI 身体动作许可仍保持关闭。

需要固件支持现有 BLE 的 `motion`、`stop`、指令 ID 确认和限时自动停止。兼容该协议的 `looi.ino` 无需为本功能重新烧录。第一次测试请架空车轮核对方向；此仓库不包含固件或你的硬件引脚配置。

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
python3 scripts/check-localization.py
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
| `icon.png` | 可直接提取的原始 1024×1024 App 图标 |
| `Tests/`, `scripts/` | 原生检查、眼睛检查、资源构建和隐私检查 |
| `docs/architecture.md` | 架构、媒体生命周期、蓝牙协议及限制 |

本项目从 [LOOI_DF26](https://github.com/xlle-er/LOOI_DF26) 的 iOS 实现整理而来，保留原有眼睛动画和小车动作代码。此副本使用全新 Git 历史，不包含原仓库历史、设备 UDID、个人开发团队、证书、密钥、照片或本机构建缓存。来源与依赖说明见 [NOTICE.md](NOTICE.md)。

## English

An independent iOS client for the LOOI desktop companion robot. It uses native SwiftUI, AVFoundation and Core Bluetooth while retaining the original eye animations and motion choreography.

### Features

- **Portrait setup, landscape companion:** configure AI and robots in portrait; starting companionship requests landscape for the eyes. Tap to reveal **退出陪伴** (Exit companion); exiting restores portrait setup.
- **Live voice and vision:** native Gemini / Vertex Live WebSocket sessions with continuous audio and optional camera frames. A small live camera preview stays visible in landscape.
- **Streaming playback:** sliced audio buffering, a short startup buffer, stall detection and bounded automatic recovery.
- **Manual remote:** switch between a joystick and direction pad, either independently or during companionship. Hold to drive and release to stop. Manual control pauses AI body movement; standalone remote starts neither AI nor camera.
- **Nearby robot list:** names, identifier suffixes, signal strength, local aliases, ownership bookmarks, device information and motion tests.
- **Provider presets:** Gemini, Vertex AI, Qwen, Groq, Fireworks, Ollama and compatible endpoints, with editable model defaults. Live speech requires a supported Live provider; other providers use text / vision requests.
- **Local credentials:** enter your own API key; credentials are stored in the iOS Keychain. Body motion is enabled by default for each new companion session and requires a connected robot. Use the companion controls to disable or re-enable it. Stops, disconnects, faults and manual remote control revoke session permission.

The app UI supports Simplified Chinese and English. In **AI services → App language**, choose System default, 简体中文 or English. App statuses and errors update with the selection; iOS permission dialogs follow the system / per-app language setting.

AI follows the language explicitly requested by the user, otherwise the language of their latest spoken or typed message, including mid-conversation changes. The UI language is only a fallback when no language cue is clear. Live speech is not pinned to the UI language. Offline mode provides fixed Chinese / English greetings rather than multilingual model responses.

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

### Remote control

Connect your robot, then open the remote from portrait setup or the landscape companion controls. Choose the joystick or direction pad, adjust relative speed, and use Stop at any time. The initial control value is 0.15, adjustable from 0.05 to 0.30; this is not a physical speed or exact motor duty cycle. After stopping, release before starting a new gesture. AI movement permission stays off after closing the remote.

Firmware must support the existing BLE `motion` / `stop` protocol, matching command-ID confirmations and duration-based stopping. Compatible `looi.ino` firmware does not need reflashing for this feature. Lift the wheels for initial direction checks. This repository does not include firmware or personal wiring configuration.

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
python3 scripts/check-localization.py
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
- [`icon.png`](icon.png): the original 1024×1024 app icon for easy extraction.
- `Tests/` and `scripts/`: checks, resource generation and privacy scanning.
- [`docs/architecture.md`](docs/architecture.md): implementation details, media lifecycle and Bluetooth protocol.

Extracted from the iOS implementation in [LOOI_DF26](https://github.com/xlle-er/LOOI_DF26), retaining original eye animations and robot motion code. This copy starts with fresh Git history and excludes the original history, device UDIDs, personal signing teams, certificates, keys, photos and local build caches. See [NOTICE.md](NOTICE.md) for provenance and dependency notices.

## DF26 设备管理 / Device management

机器人列表中的“设备管理”支持 BLE 配网、Wi-Fi 连接与发现、电机方向校准、300 毫秒点动测试、本地 `.bin` 和在线 OTA。最终硬件不含俯仰舵机，连接后不再自动点头。首次 USB 安装和管理密码见 [Firmware 仓库](https://github.com/xlle-er/LOOI-DF26-Firmware)。在线清单使用该仓库的稳定 Release。

Device management in the robot list supports BLE provisioning, LAN discovery/Wi-Fi control, persistent motor calibration, 300 ms tests, local `.bin` and online OTA. The final chassis has no pitch servo and never moves automatically for identification. See the Firmware repository for first installation and the management password. Online manifests come from its stable Releases.

## 热点升级与联网恢复 / Hotspot update and internet recovery

先在有互联网时检查版本、下载并校验固件，再连接 ESP 热点上传。网页使用本机浏览器存储，App 使用自己的文件存储；已下载文件可在页面或 App 重启后继续使用。重新上传前再次校验，失败下载不会替换上一个完整包。

“升级后关闭 ESP 热点”默认开启，需要设备固件 2.0.1 或更新版本支持。只有成功校验并切换到 OTA 目标分区后，下次启动才跳过自动开启热点；不会删除网络或方向设置，BLE 仍可用，长按 BOOT 3 秒可重新打开热点。该设置只影响升级后的这次启动，普通断电重启仍按原配网策略工作。关闭设备热点不保证手机自动恢复互联网，启动 AI 陪伴前应检查手机流量或可上网的 Wi-Fi。

从仅热点 OTA 初版或 2.0.0 首次升级时，旧固件无法保存这个选项：先下载 `.bin`，再通过 `http://192.168.4.1/` 的设备面板上传，完成后手动断开热点。App/网页管理接口不保证兼容仅热点 OTA 初版。2.0.1 的关闭开关对安装该版本之后发起的 OTA 生效。

Download and verify firmware while online, then join the ESP hotspot to upload. Prepared packages survive page/app restarts and are verified again before upload. Failed downloads preserve the last complete package.

Close ESP hotspot after update is enabled by default and requires device firmware 2.0.1+. After a verified OTA activates its target partition, the next boot skips automatic hotspot startup. Network and calibration settings remain intact; BLE stays available and holding BOOT for three seconds reopens the hotspot. This is a one-boot choice; ordinary subsequent power cycles use normal provisioning behavior. Your phone decides whether internet reconnects automatically. Restore mobile data or internet Wi-Fi before AI companionship.

The initial hotspot-only firmware and 2.0.0 cannot store this option. For the first upgrade, download the application `.bin`, join the hotspot and upload it through the device's own panel at `http://192.168.4.1/`, then leave the hotspot manually. Modern management APIs are not guaranteed on the initial firmware. The 2.0.1 option applies to OTA operations initiated after that firmware is installed.


## 预览版固件更新 / Preview firmware updates

设备管理 → 固件升级提供“预览版更新”开关，默认关闭，并记住本客户端的选择。关闭时只使用稳定版更新源；开启时使用独立预览通道，版本可能尚未完成硬件验证。检查结果和已下载固件均显示通道标签。切换通道会清空当前检查结果；关闭开关后，已缓存的预览包保留，但不能上传，需重新开启或下载稳定版。手动选择本地 .bin 不受在线通道开关限制，仍执行设备兼容和校验检查。

Device management → Firmware update has a persistent **Preview firmware updates** toggle, off by default. Off selects stable releases; on selects the separate preview feed. Results and offline packages show their channel. Turning previews off blocks cached preview installation without deleting the package. Manually chosen local files remain an explicit action and still undergo compatibility/checksum validation.
