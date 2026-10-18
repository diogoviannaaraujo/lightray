import AppKit
import CoreImage.CIFilterBuiltins
import LightrayHostSupport
import SwiftUI

/// Names a new device, shows its code once while the host waits for its first connection, and
/// confirms when it pairs. Closing the sheet before then withdraws the code.
@MainActor struct AddDeviceSheet: View {
    @Bindable var model: HostSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.addDevice {
            case .naming?: naming
            case .waiting(let device, let invite)?: waiting(device, invite: invite.string)
            case .paired(let device)?: paired(device)
            case .expired(let name)?: expired(name)
            case nil: EmptyView()
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var naming: some View {
        Group {
            Text("Add a Device").font(.title2.weight(.semibold))
            Text("Name the device you are pairing. It gets a code of its own, which works until it first connects.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Device name", text: $model.newDeviceName, prompt: Text("iPad"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.beginAdding)
            message
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: model.closeAddDevice).keyboardShortcut(.cancelAction)
                Button("Continue", action: model.beginAdding)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.newDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func waiting(_ device: PairedDevice, invite: String) -> some View {
        Group {
            Text("Pair \(device.name)").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 18) {
                QRCode(text: invite)
                    .frame(width: 180, height: 180)
                    .accessibilityLabel("Pairing QR code for \(device.name)")
                VStack(alignment: .leading, spacing: 10) {
                    Text("On iPad, open Lightray, choose Add computer, then Scan QR Code.")
                    Text("On a Mac, choose Add Host, enter \(Text(model.address).font(.body.monospaced())), and paste the code.")
                    HStack {
                        Button("Copy Code", systemImage: "doc.on.doc", action: model.copyCode)
                        Button("Save to File…", systemImage: "square.and.arrow.down", action: model.exportCode)
                    }
                    .padding(.top, 4)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            message
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for \(device.name) to connect…")
                    if let expires = device.expires {
                        Text("This code stops working in \(Text(expires, style: .timer)) or once \(device.name) connects. It won’t be shown again.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: model.closeAddDevice).keyboardShortcut(.cancelAction)
            }
        }
    }

    private func paired(_ device: PairedDevice) -> some View {
        Group {
            Label("\(device.name) is paired", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            Text("It can connect whenever sharing is on. To stop it, revoke it in Paired Devices.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: model.closeAddDevice).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func expired(_ name: String) -> some View {
        Group {
            Label("The code for \(name) expired", systemImage: "clock.badge.exclamationmark")
                .font(.title2.weight(.semibold))
            Text("Nothing connected with it, so it no longer works. Add the device again to get a new code.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close", role: .cancel, action: model.closeAddDevice).keyboardShortcut(.cancelAction)
                Button("Try Again", action: model.retryAdding).keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var message: some View {
        if let message = model.addDeviceMessage {
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// A QR code drawn with square modules on white, which scanners read in light and dark mode.
private struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary)
        }
    }

    private static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
