import AVFoundation
import SwiftUI
import TossCore
import UIKit

struct PairingScannerView: View {
    @Environment(TossEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorized = false
    @State private var checkedPermission = false
    @State private var cameraUnavailable = false
    @State private var error: String?
    @State private var showManual = false
    @State private var manualLink = ""
    @State private var candidate: PairingOffer?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    switch engine.pairingProgress {
                    case .connecting(let name):
                        ProgressView().controlSize(.large).padding(.top, 50)
                        Text("Connecting to \(name)…").font(.title2.bold())
                        Text("Keep Toss open on both devices. This usually takes a few seconds.")
                            .foregroundStyle(.secondary)
                        Button("Cancel Connection") { engine.cancelPairing(); candidate = nil }
                    case .connected(let name):
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.tint).padding(.top, 40)
                        Text("You're connected").font(.title.bold())
                        Text("\(name) is ready. Use the Send tab to send your first item.").foregroundStyle(.secondary)
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
                    case .failed(let guidance):
                        ContentUnavailableView {
                            Label("Couldn't connect", systemImage: "wifi.exclamationmark")
                        } description: { Text(guidance) } actions: {
                            Button("Scan a New Code") { engine.cancelPairing(); candidate = nil; error = nil }
                                .buttonStyle(.borderedProminent)
                            Button("Open Settings") { openAppSettings() }
                        }
                    case .idle:
                        if let candidate {
                            Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 48)).foregroundStyle(.tint).padding(.top, 24)
                            Text("Connect to \(candidate.deviceName)?").font(.title2.bold())
                            Text(candidate.verificationCode).font(.system(.title2, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                            Text("Check that this code matches the one shown on your Mac before connecting.")
                                .foregroundStyle(.secondary)
                            Button("Connect") {
                                do {
                                    guard let url = candidate.url else { throw TossError.invalidPairingCode }
                                    try engine.pair(using: url)
                                } catch { self.error = "This code has expired. Choose New Code on your Mac, then scan it again." }
                            }.buttonStyle(.borderedProminent).controlSize(.large)
                            Button("Scan a Different Code") { self.candidate = nil; error = nil }
                        } else {
                            scanContent
                        }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .multilineTextAlignment(.center).padding(24).frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Connect a Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await checkCameraPermission() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await checkCameraPermission() } }
            }
            .onDisappear { engine.cancelPairing() }
            .alert("Pairing Link", isPresented: $showManual) {
                TextField("toss://pair…", text: $manualLink).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Review Code") { review(manualLink) }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Use a link copied from Toss → Devices → Add Device on your Mac.") }
        }
    }

    @ViewBuilder private var scanContent: some View {
        Text("One quick connection. All your devices, together.").font(.title2.bold())
        Text("On your Mac, open Toss → Devices → Add Device. Keep both devices nearby for this step.")
            .foregroundStyle(.secondary)
        if authorized && !cameraUnavailable {
            QRScanner(onScan: { if candidate == nil { review($0) } }, onUnavailable: { cameraUnavailable = true })
                .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Camera scanning for a Toss pairing code")
        } else if checkedPermission {
            ContentUnavailableView {
                Label(cameraUnavailable ? "Camera unavailable" : "Camera access is off", systemImage: "camera")
            } description: {
                Text("Allow camera access in Settings, or use a pairing link copied from your Mac.")
            } actions: {
                Button("Open Settings") { openAppSettings() }.buttonStyle(.bordered)
            }
        } else { ProgressView("Requesting camera access…") }
        Button("Paste Pairing Link") {
            manualLink = UIPasteboard.general.string ?? ""
            showManual = true
        }
    }

    private func review(_ value: String) {
        do {
            guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TossError.invalidPairingCode }
            candidate = try PairingOffer(url: url)
            error = nil
        } catch {
            self.error = "This isn't a valid, current Toss code. Choose New Code on your Mac and try again."
        }
    }
    private func checkCameraPermission() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        } else { authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
        checkedPermission = true
    }
}

private struct QRScanner: UIViewRepresentable {
    let onScan: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIView(context: Context) -> CameraPreview {
        let view = CameraPreview()
        let session = context.coordinator.session
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            DispatchQueue.main.async { onUnavailable() }
            return view
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        view.previewLayer?.session = session
        view.previewLayer?.videoGravity = .resizeAspectFill
        context.coordinator.sessionQueue.async { session.startRunning() }
        return view
    }

    func updateUIView(_ uiView: CameraPreview, context: Context) {}
    static func dismantleUIView(_ uiView: CameraPreview, coordinator: Coordinator) {
        coordinator.sessionQueue.async { coordinator.session.stopRunning() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let sessionQueue = DispatchQueue(label: "toss.camera", qos: .userInitiated)
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = code.stringValue else { return }
            onScan(value)
        }
    }
}

private final class CameraPreview: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
}
