import AVFoundation
import RawLabKit
import SwiftUI

struct IOSCameraQRScannerSheet: View {
    let onScanned: (CameraWifiQrCredentials) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var unavailable = false
    @State private var invalidQRHint = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch authorizationStatus {
                case .authorized:
                    if unavailable {
                        unavailableView
                    } else {
                        IOSCameraQRScannerView(
                            onScanned: { credentials in
                                dismiss()
                                onScanned(credentials)
                            },
                            onInvalidQR: { invalidQRHint = true },
                            onUnavailable: { unavailable = true }
                        )
                        .ignoresSafeArea()
                        scannerOverlay
                    }
                case .notDetermined:
                    ProgressView()
                        .tint(.white)
                case .denied, .restricted:
                    permissionDeniedView
                @unknown default:
                    unavailableView
                }
            }
            .navigationTitle(L10n.text("扫描相机二维码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { dismiss() }
                        .accessibilityIdentifier("camera.qr.cancel")
                }
            }
            .task {
                guard authorizationStatus == .notDetermined else { return }
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                authorizationStatus = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("camera.qr.sheet")
    }

    private var scannerOverlay: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                .frame(width: 240, height: 240)
                .allowsHitTesting(false)
            Spacer()
            VStack(spacing: 8) {
                Text(L10n.text("对准相机「智能手机连接」画面中的二维码"))
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if invalidQRHint {
                    Text(L10n.text("未识别到相机 Wi-Fi 二维码，请对准相机屏幕上的二维码。"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("camera.qr.invalid")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.65))
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L10n.text("需要相机权限才能扫描相机二维码，请允许相机权限或在下方手动连接 Wi-Fi。"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(L10n.text("系统权限设置")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
        }
        .padding(24)
    }

    private var unavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L10n.text("无法打开相机扫码，请改用手动连接 Wi-Fi。"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct IOSCameraQRScannerView: UIViewControllerRepresentable {
    let onScanned: (CameraWifiQrCredentials) -> Void
    let onInvalidQR: () -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScanned = onScanned
        controller.onInvalidQR = onInvalidQR
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.onScanned = onScanned
        uiViewController.onInvalidQR = onInvalidQR
        uiViewController.onUnavailable = onUnavailable
    }
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((CameraWifiQrCredentials) -> Void)?
    var onInvalidQR: (() -> Void)?
    var onUnavailable: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "rawlab.camera.qr-scanner")
    private var captureDevice: AVCaptureDevice?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false
    private var delivered = false
    private var lastInvalidAt = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tap)
        configureAndStart()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: recognizer.location(in: view))
        sessionQueue.async { [weak self] in
            self?.focusAndExpose(at: devicePoint)
        }
    }

    private func focusAndExpose(at point: CGPoint) {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch {
            // Keep default capture configuration when locking fails.
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    deinit {
        stopSession()
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.onUnavailable?() }
                    return
                }
                let output = AVCaptureMetadataOutput()
                guard self.session.canAddOutput(output) else {
                    DispatchQueue.main.async { self.onUnavailable?() }
                    return
                }
                self.session.beginConfiguration()
                if self.session.canSetSessionPreset(.hd1920x1080) {
                    self.session.sessionPreset = .hd1920x1080
                }
                self.session.addInput(input)
                self.session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.onUnavailable?() }
                    return
                }
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                output.metadataObjectTypes = [.qr]
                self.session.commitConfiguration()
                self.captureDevice = device
                self.focusAndExpose(at: CGPoint(x: 0.5, y: 0.5))
                if device.activeFormat.videoMaxZoomFactor >= 2.0 {
                    do {
                        try device.lockForConfiguration()
                        device.videoZoomFactor = min(1.5, device.activeFormat.videoMaxZoomFactor)
                        device.unlockForConfiguration()
                    } catch {
                        // Ignore zoom errors on constrained devices.
                    }
                }
                self.configured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func stopSession() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered else { return }
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  readable.type == .qr,
                  let payload = readable.stringValue else { continue }
            if let parsed = CameraWifiQrCode.parse(payload) {
                delivered = true
                stopSession()
                onScanned?(parsed)
                return
            }
            let now = Date()
            if now.timeIntervalSince(lastInvalidAt) >= 1.5 {
                lastInvalidAt = now
                onInvalidQR?()
            }
        }
    }
}
