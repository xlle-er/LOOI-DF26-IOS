# iOS native architecture

The iOS app now starts in a programmatic UIKit scene hosting SwiftUI. It does not
start Capacitor, the frontend application, a backend server, or a JavaScript
provider/state/lifecycle layer. Its only WKWebView is an isolated local eyes and
motion component, packaged as approximately 144 KB of JavaScript/CSS/HTML.

## Ownership

| Module | Responsibility |
| --- | --- |
| `LooiAppModel` | Main-actor companion lifecycle, cancellation, service coordination |
| `LooiNativeShell`, `LooiCompanionControls` | Native portrait/landscape companion UI |
| `LooiRobotList` | Native nearby-device list, explicit selection, aliases and ownership bookmark |
| `LooiBluetooth` | Main-actor Core Bluetooth discovery, connection, GATT writes, ACK matching, timeouts |
| `LooiBodyProtocol` | Native command boundaries, stop framing, fragmented notification decoder |
| `LooiCamera` | Serial-queue AVCaptureSession, preview, orientation, bounded JPEG sampling |
| `LooiAudioOutput` | One AVAudioEngine for microphone and playback, PCM conversion and interruption handling |
| `LooiPlaybackQueue` | Bounded PCM buffering, short scheduling window, completion accounting and recovery ordering |
| `LooiLiveConfiguration` | Isolated, short audio-test setup without companion history or tools |
| `LooiLiveService` | Direct URLSession WebSocket, setup acknowledgment, continuous media, tools and resumption |
| `LooiAIRequest` | Native Gemini/Vertex/compatible/Ollama text and image requests |
| `LooiSettings`, `LooiCredentials` | Local public settings, Keychain credentials, native Google authorization |
| `LooiFaceHost` | Local-only WebKit presentation and narrow command/photo bridge |

Root ownership is stable. Services are event driven; there is no 500 ms JS-to-Swift
UI polling. Camera setup and frame conversion run on a dedicated queue. High-rate
PCM counters do not publish SwiftUI changes. BLE RSSI is smoothed and updated at
most about once per second per device. Scanning stops after 15 seconds, on sheet
exit, on connect and on backgrounding.

### Portrait setup and landscape companion

The portrait home is a native setup screen with robot selection, AI configuration,
camera controls and tests. The original eye host retains its identity for motion
execution, but is invisible and excluded from accessibility in portrait.
Starting or connecting requests landscape through the hosting controller's supported
orientation mask and `UIWindowScene.requestGeometryUpdate` (iOS 16+). A failed start,
exit or background stop restores the portrait setup mask; UIKit updates camera
orientation after the transition. On iOS 15 the legacy supported-orientation
rotation path applies, and physical rotation can be necessary.

Landscape companion retains a small native live-camera preview at the upper left
while the camera is running, even after the controls fade. It uses the existing
AVCaptureSession, not the one-frame-per-second AI JPEG feed. The preview disappears
when capture stops and does not consume taps intended to reveal controls. Tapping the
screen reveals a native **退出陪伴** button and media controls. Exit stops the session
and requests portrait immediately while body-stop acknowledgment completes. Controls
remain visible for text conversations and VoiceOver. Settings and device lists are
opened from portrait. Orientation denial leaves an actionable notice and the exit
button available. Physical scene rotation still needs iPhone verification.

### Speech buffering and recovery

Both AI testing and normal Live conversations use the same playback queue. Incoming
24 kHz PCM is split into slices of at most 200 ms. An 80 ms initial prebuffer absorbs
small arrival variations; only 600 ms is scheduled on AVAudioPlayerNode at a time.
The remaining audio is held in a bounded queue (60 seconds, approximately 5.8 MB
of Float32 samples). A 30-second burst no longer trips the former 20-second guard.
This buffer does not deliberately delay the start until the full reply arrives.

A main-run-loop watchdog checks playback every 250 ms while audio is pending.
After two seconds without a playback completion, or if the engine/player stops,
it attempts to restart output while retaining the microphone tap and Live socket.
Only the unconfirmed scheduling window is replayed, so recovery can repeat up to
600 ms of speech. Old completion callbacks are invalidated before stopping the
node. Recovery is limited to two attempts per continuously buffered episode.

If output cannot recover or the memory bound is reached, the remaining audio for
that reply is discarded and a single actionable error is shown; microphone,
camera and Live connection are not torn down. OS audio interruptions still follow
AVAudioSession interruption handling. This is not a guarantee of uninterrupted
playback under every route or system interruption.

AI testing uses an independent one-sentence system instruction, no tools or
conversation resumption, and a 256-token output limit. Switching between test and
companion sessions clears the resume handle. Queue ordering, bounded scheduling,
burst draining, stale callbacks, recovery, cancellation and test configuration are
covered by the native Swift checks. Device speaker/microphone behavior still
requires testing on iPhone.

## Preserved code

`FaceSource/mobile/face/entry.js` imports the original `FaceSource/frontend/js/ui/faceCanvas.js`, eye styles,
`scenarioCatalog.js`, scenario actions, `ScenarioFrameSequencer`, `CommandQueue`,
`ESP32Client` protocol builder and motion safety validator. These remain the source
of eye behavior and movement choreography. The transport adapter forwards
commands to native Core Bluetooth and only resolves a write after a matching
firmware ACK. Native validation bounds physical commands independently.

The resource builder bundles only those imports. The page has no AI, microphone,
camera, account, BLE scanning, application lifecycle or settings implementation.
Its CSP disallows network connections, navigation stays within the resource
directory, and the bridge supports only body commands and camera snapshots.

## Bluetooth identity and connection

Each discovered device is a stable Core Bluetooth UUID row with advertising name,
an eight-character identifier suffix, smoothed RSSI, signal label and connection
state. RSSI is not presented as a measured physical distance. Rows keep their
identity and discovery order so fluctuating signal strength does not move a
connect button under a finger.

Users explicitly choose a row; the app does not auto-connect to the strongest
signal. A local alias, explicit **设为我的机器人** bookmark, and a separate **上次连接**
label help identify devices with the same advertising name. The UUID and alias
are local to that phone; no Bluetooth MAC address is claimed. After connecting,
**让已连接的机器人点头** sends bounded head-pitch commands without wheel movement.
It requires the project's head-pitch-capable firmware.

Connection includes service/characteristic discovery, notifications and ping/config
requests. It has a 12-second connection timeout, cancellation, serialized MTU-sized
writes, a bounded queue, five-second command confirmation timeouts and notification
reassembly across UTF-8 byte boundaries. Emergency stop cancels queued motion,
separates a partially written JSON frame, and coalesces simultaneous stop requests.
Movement faults disarm motion while leaving the AI conversation available.

## Media and lifecycle

Start/stop/testing are explicit native phases. A generation token invalidates old
asynchronous startup, test and provider responses. Temporary inactive states do
not stop the app; actual backgrounding cancels capture, invalidates tools, releases
the idle timer and sends body stop. Motion permission starts off on each launch
and is cleared on disconnect, a body failure or companion stop.

The camera samples JPEG at no more than one frame per second. Native microphone
input and playback share an AVAudioEngine with voice processing; incoming speech
does not replace or deactivate the recording session. Camera frames continue
during model output and tool turns. Capture can be restored without opening a new
AI connection when the existing socket is healthy. Camera permission refusal can
fall back to voice-only companionship.

AI starts sending microphone data only after setupComplete. Speech interruption
clears only the output buffers, preserving capture. Cancelled tool IDs do not
receive late responses. The socket writer is ordered and bounded; video is dropped
before a backlog can grow indefinitely. Explicit stop and provider changes close
the socket and deactivate audio. Credentials use request headers, not URLs.

Text conversations attach an image only after an explicit image-button selection;
text-only model defaults therefore work with the camera enabled. Text-provider
action responses are decoded in Swift against the original scenario allowlist and
still pass through native motion permission and command validation. AI connection
tests never execute model-requested movement. Stop phrases disarm body movement
without ending the conversation.

## Localization and conversation language

`LooiLocalization` owns a persisted System default / Simplified Chinese / English
selection. Standard `.lproj/Localizable.strings` resources live in the Swift Package;
localized permission descriptions live in the application target. Native views
observe language changes without recreating the app model or discarding a settings
draft. Services retain source messages; known status and error strings are translated
when displayed. Model replies, user text, custom model IDs and robot aliases remain
opaque. System permission sheets follow iOS system/per-app language preferences.

`LooiConversationLanguage` builds a shared policy for Live and text providers:
explicit user language requests take precedence, followed by the latest spoken or
typed input; UI language is only the fallback. The policy applies on every turn.
Live setup removes the previous language block and any pinned speech language code,
while retaining identity, tool and safety rules. Text providers send policy as a
system instruction separately from user content. Changing interface language clears
resumption across subsequent Live sessions; it does not tear down a running call.
Language selection is disabled outside the idle phase. Offline mode recognizes
Chinese/English for fixed greetings; other languages require an AI provider.

## Models and migration

Provider presets fill a default model and offer a menu plus custom input. Existing
custom models are preserved when migrating `CapacitorStorage.looi.providers.v1` to
native version-2 preferences. The standalone copy uses a neutral Keychain service namespace and ships no saved
credentials or preference files. Users configure their own keys. Public preferences
contain no keys. Local provider models still need installation on the host.

Presets checked on 2026-10-15:

| Provider | Default text model | Default Live model |
| --- | --- | --- |
| Gemini | `gemini-3.8-flash` | `gemini-3.8-live` |
| Vertex | `gemini-3.8-flash` | `gemini-3.8-live` (`us-central1` for a fresh profile) |
| Qwen | `qwen-plus` | — |
| Groq | `openai/gpt-oss-120b` | — |
| Fireworks | `accounts/fireworks/models/llama-v3p3-70b-instruct` | — |
| Ollama | `qwen3:8b` | — |

References: [Gemini Flash](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash),
[Gemini Live](https://ai.google.dev/gemini-api/docs/live-api/capabilities),
[Vertex Live](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-8-live),
[Qwen](https://help.aliyun.com/zh/model-studio/qwen-plus),
[Groq](https://console.groq.com/docs/models),
[Fireworks](https://fireworks.ai/models/fireworks/llama-v3p3-70b-instruct),
[Ollama](https://ollama.com/library/qwen3).
These are convenience presets, not evidence that every account has model access.

## Build and validate

```sh
npm run build:resources
python3 scripts/test-native.py
npm run test:face
xcodebuild -project LOOI.xcodeproj -scheme LOOI \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath build/ios-native CODE_SIGNING_ALLOWED=NO build
```

The canonical Swift sources are under `Native/Sources/LooiNative`; Xcode compiles
them directly. Bundled resources are committed so Node.js is optional for normal
Xcode builds. Only changes to `FaceSource/` require `npm ci` followed by
`npm run build:resources`. Resource generation never copies credentials or settings.

Native Swift tests exercise migration, default models, request building, response
validation, secret redaction, motion boundaries, stop framing and notification
decoding. Browser tests exercise the actual preserved eye/motion bundle with a
simulated native ACK transport. Unsigned device compilation verifies Swift and
resource linkage. These do not validate real BLE radio behavior, physical movement,
on-device audio/camera operation or measured cold-launch timing. Verify those on
an iPhone after installing your own signed build.
