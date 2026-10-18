import LightrayCore
import SwiftUI
import VisionKit

/// Reads the QR code Lightray Host shows when adding a device. Only a code that parses as a
/// pairing invite is taken; anything else in view is ignored.
struct PairingScannerView: View {
    let found: (PairingInvite) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    static var isSupported: Bool { DataScannerViewController.isSupported }

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    ContentUnavailableView("Can’t Scan", systemImage: "camera", description: Text(failure))
                } else {
                    QRScanner(found: { invite in found(invite); dismiss() }, failed: { failure = $0 })
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if failure == nil {
                    Text("On your Mac, open Lightray Host › Pairing › Add Device, and point the camera at its code.")
                        .font(.callout).multilineTextAlignment(.center)
                        .padding().frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let found: (PairingInvite) -> Void
    let failed: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.found = found
        guard !scanner.isScanning, !context.coordinator.done else { return }
        do { try scanner.startScanning() } catch {
            let message = DataScannerViewController.isAvailable
                ? "The camera could not start: \(error.localizedDescription)"
                : "Allow camera access for Lightray in Settings, or paste the pairing code instead."
            DispatchQueue.main.async { failed(message) }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var found: (PairingInvite) -> Void
        var done = false
        init(found: @escaping (PairingInvite) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                guard case .barcode(let code) = item, let text = code.payloadStringValue,
                      let invite = PairingInvite(string: text) else { continue }
                done = true
                dataScanner.stopScanning()
                found(invite)
                return
            }
        }
    }
}
