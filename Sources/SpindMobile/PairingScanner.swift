// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AVFoundation
import CoreImage
import PhotosUI
import SpindCore

/// Camera scanner for the pairing code from the Mac app.
struct PairingScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var handled = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            Task.detached { [session] in session.startRunning() }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !handled,
                  let code = objects.compactMap({
                      ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue
                  }).first
            else { return }
            handled = true
            session.stopRunning()
            onCode?(code)
        }
    }
}

/// Pairing: scan the code, or pick a screenshot of it from the library.
struct PairingView: View {
    var onPaired: () -> Void
    var dismiss: () -> Void

    @State private var message: String?
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PairingScanner { code in apply(code) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 10) {
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Den QR-Code aus der Mac-App scannen (Einstellungen → Verbindung → »Gerät verbinden«).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Screenshot aus Fotos wählen", systemImage: "photo")
                    }
                }
                .padding()
            }
            .navigationTitle("Gerät verbinden")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let code = Self.readQR(from: data) else {
                        message = "In diesem Bild war kein Spind-Code zu finden."
                        return
                    }
                    apply(code)
                }
            }
        }
    }

    /// Read a QR from an image — for codes that arrive on the iPhone by
    /// AirDrop or as a screenshot instead of being scanned off a screen.
    static func readQR(from data: Data) -> String? {
        guard let image = CIImage(data: data) else { return nil }
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        return (detector?.features(in: image) as? [CIQRCodeFeature])?
            .compactMap(\.messageString).first
    }

    private func apply(_ text: String) {
        guard let code = PairingCode.decode(text) else {
            message = "Das ist kein Spind-Kopplungscode."
            return
        }
        do {
            try MobileStore.applyPairing(code)
            onPaired()
        } catch {
            message = error.localizedDescription
        }
    }
}
