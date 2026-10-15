import AVFoundation
import CoreImage
import Combine
import SwiftUI

// UI control is main-thread owned; session/sample work uses captureQueue and JPEG access uses frameLock.
final class LooiCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published private(set) var running = false
    @Published private(set) var front = true
    @Published private(set) var message = ""
    var onFrame: ((Data) -> Void)?
    private let captureQueue = DispatchQueue(label: "app.looi.camera", qos: .userInitiated)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var lastFrameTime = 0.0
    private var videoOrientation: AVCaptureVideoOrientation = .portrait
    private let frameLock = NSLock()
    private var latestFrame: Data?
    private var intent = 0
    private var observers: [NSObjectProtocol] = []
    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            self?.message = "摄像头暂时被系统占用，可稍后恢复采集"
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in self?.message = "" })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
            self?.running = false; self?.message = "摄像头发生中断，请恢复采集"
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    @MainActor func start(front useFront: Bool = true) async throws {
        updateOrientation()
        intent += 1; let generation = intent
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard generation == intent else { throw CancellationError() }
        guard granted else { throw LooiError.message("请在 iPhone 设置中允许 LOOI 使用摄像头") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                do {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .vga640x480
                    self.session.inputs.forEach(self.session.removeInput)
                    self.session.outputs.forEach(self.session.removeOutput)
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: useFront ? .front : .back) else {
                        self.session.commitConfiguration(); throw LooiError.message("找不到摄像头")
                    }
                    let input: AVCaptureDeviceInput
                    do { input = try AVCaptureDeviceInput(device: device) }
                    catch { self.session.commitConfiguration(); throw error }
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.setSampleBufferDelegate(self, queue: self.captureQueue)
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration(); throw LooiError.message("无法建立摄像头采集")
                    }
                    self.session.addInput(input); self.session.addOutput(output)
                    if let connection = output.connection(with: .video) {
                        if connection.isVideoOrientationSupported { connection.videoOrientation = self.videoOrientation }
                        if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = useFront }
                    }
                    self.session.commitConfiguration()
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        guard generation == intent else { throw CancellationError() }
        running = true; front = useFront; message = ""
    }
    @MainActor func stop() {
        intent += 1; running = false
        frameLock.lock(); latestFrame = nil; frameLock.unlock()
        captureQueue.async { self.session.stopRunning() }
    }
    @MainActor func updateOrientation() {
        let interface = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive })?.interfaceOrientation ?? .portrait
        let orientation = Self.captureOrientation(interface)
        captureQueue.async {
            self.videoOrientation = orientation
            for output in self.session.outputs {
                if let connection = output.connection(with: .video), connection.isVideoOrientationSupported { connection.videoOrientation = orientation }
            }
        }
    }
    static func captureOrientation(_ value: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        switch value {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
    func snapshot() -> Data? { frameLock.lock(); defer { frameLock.unlock() }; return latestFrame }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= 1, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = now
        let image = CIImage(cvPixelBuffer: buffer)
        guard let data = imageContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) else { return }
        frameLock.lock(); latestFrame = data; frameLock.unlock()
        DispatchQueue.main.async { [weak self] in guard let self, self.running else { return }; self.onFrame?(data) }
    }
}

private final class LooiPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = LooiCamera.captureOrientation(window?.windowScene?.interfaceOrientation ?? .portrait)
        }
    }
}
struct LooiCameraPreview: UIViewRepresentable {
    let camera: LooiCamera
    func makeUIView(context: Context) -> UIView {
        let view = LooiPreviewUIView(); view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill; return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? LooiPreviewUIView, let connection = view.previewLayer.connection else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = LooiCamera.captureOrientation(uiView.window?.windowScene?.interfaceOrientation ?? .portrait) }
        if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = camera.front }
    }
}
