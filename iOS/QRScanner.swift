import SwiftUI
import AVFoundation

/// Camera view that reads a two-factor QR code (otpauth://) and hands back the text.
/// Frames never leave the device and nothing is saved.
struct QRScannerView: View {
    var title = "Scan 2FA QR code"
    var hint = "On the site's security page, turn two-factor on and point the camera at its QR code."
    var accept: (String) -> Bool = { $0.lowercased().hasPrefix("otpauth://") && TOTP($0) != nil }
    var onResult: (String?) -> Void
    @State private var denied = false

    var body: some View {
        ZStack {
            Ink.bg.ignoresSafeArea()
            if denied {
                VStack(spacing: 12) {
                    Text("Camera is off for Vault.").font(.plex(17, .medium)).foregroundStyle(Ink.text)
                    Text("Turn it on in Settings to scan two-factor QR codes, or paste the setup key instead.")
                        .font(.plex(15)).foregroundStyle(Ink.mid).multilineTextAlignment(.center)
                }
                .padding(24)
            } else {
                CameraPreview(accept: accept) { onResult($0) }.ignoresSafeArea()
                RoundedRectangle(cornerRadius: 6).stroke(Ink.amber, lineWidth: 2).frame(width: 240, height: 240)
            }
            VStack {
                HStack {
                    Eyebrow(title, color: Ink.text)
                    Spacer()
                    CapsButton("Cancel", color: Ink.text) { onResult(nil) }
                }
                .padding(.horizontal, 16)
                Spacer()
                Text(hint)
                    .font(.plex(14)).foregroundStyle(Ink.text).multilineTextAlignment(.center)
                    .padding(16).background(Ink.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 6)).padding(16)
            }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: break
            case .notDetermined: denied = !(await AVCaptureDevice.requestAccess(for: .video))
            default: denied = true
            }
        }
    }
}

private struct CameraPreview: UIViewControllerRepresentable {
    var accept: (String) -> Bool
    var found: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let c = ScannerController(); c.accept = accept; c.found = found; return c }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var found: (String) -> Void = { _ in }
    var accept: (String) -> Bool = { _ in true }
    private let session = AVCaptureSession()
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              accept(s) else { return }
        done = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        session.stopRunning()
        found(s)
    }
}
