import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScannerStatus: Decodable {
    var macos: String
    var arch: String
    var backendInstalled: Bool
    var usbPresent: Bool
    var saneDevice: String?
    var cupsQueues: [String]
    var ready: Bool
    var message: String

    enum CodingKeys: String, CodingKey {
        case macos, arch, ready, message
        case backendInstalled = "backend_installed"
        case usbPresent = "usb_present"
        case saneDevice = "sane_device"
        case cupsQueues = "cups_queues"
    }
}

@MainActor
final class ScannerModel: ObservableObject {
    @Published var status: ScannerStatus?
    @Published var dpi = 300
    @Published var mode = "color"
    @Published var paper = "a4"
    @Published var scanning = false
    @Published var log = "Checking the DeskJet 1050…"
    @Published var lastFile: String?

    let resolutions = [75, 100, 150, 200, 300, 600, 1200]
    private var binary: String {
        let installed = "/opt/homebrew/bin/dj1050-scan"
        if FileManager.default.isExecutableFile(atPath: installed) {
            return installed
        }
        return "dj1050-scan"
    }

    func refresh() {
        Task {
            let (code, text) = await Self.run(binary, ["status"])
            guard let data = text.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(ScannerStatus.self, from: data) else {
                status = nil
                log = code == 0 ? text : "Could not read scanner status.\n\(text)"
                return
            }
            status = decoded
            log = decoded.message
        }
    }

    func scan() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "DeskJet1050-\(Self.stamp()).pdf"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.title = "Save scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        scanning = true
        log = "Scanning the glass. Keep the lid closed."
        let args = [
            "scan",
            "--dpi", String(dpi),
            "--mode", mode,
            "--paper", paper,
            "--format", "pdf",
            "--output", url.path,
            "--no-open",
        ]
        Task {
            let (code, text) = await Self.run(binary, args)
            scanning = false
            log = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0 {
                lastFile = url.path
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showInImageCapture() {
        log = "Publishing the scanner to Image Capture…"
        Task {
            let (code, text) = await Self.run(binary, ["bridge", "--install-agent"])
            log = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0 {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Image Capture.app"))
            }
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func run(_ binary: String, _ args: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            var environment = ProcessInfo.processInfo.environment
            let brew = "/opt/homebrew/bin"
            environment["PATH"] = brew + ":" + (environment["PATH"] ?? "")
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (finished.terminationStatus, text))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (1, error.localizedDescription))
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ScannerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DeskJet 1050")
                    .font(.title.weight(.semibold))
                Text("Flatbed scanner for the HP DeskJet 1050 J410 on this Mac")
                    .foregroundStyle(.secondary)
            }

            statusCard

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Resolution")
                    Picker("Resolution", selection: $model.dpi) {
                        ForEach(model.resolutions, id: \.self) { value in
                            Text("\(value) DPI").tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }
                GridRow {
                    Text("Color")
                    Picker("Color", selection: $model.mode) {
                        Text("Color").tag("color")
                        Text("Grayscale").tag("gray")
                        Text("Black and white").tag("lineart")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                GridRow {
                    Text("Page")
                    Picker("Page", selection: $model.paper) {
                        Text("A4").tag("a4")
                        Text("Letter").tag("letter")
                        Text("Full glass").tag("full")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            HStack {
                Button("Refresh") { model.refresh() }
                    .disabled(model.scanning)
                Button("Image Capture") { model.showInImageCapture() }
                    .disabled(model.scanning)
                Spacer()
                Button(model.scanning ? "Scanning…" : "Scan") { model.scan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.scanning || model.status?.ready != true)
            }

            Text(model.log)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 460)
        .onAppear { model.refresh() }
    }

    private var statusCard: some View {
        let ready = model.status?.ready == true
        let connected = model.status?.usbPresent == true
        return HStack(spacing: 10) {
            Circle()
                .fill(ready ? Color.green : (connected ? Color.orange : Color.secondary))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(ready ? "Scanner ready" : (connected ? "Printer on USB" : "Printer not connected"))
                    .font(.headline)
                if let device = model.status?.saneDevice, !device.isEmpty {
                    Text(device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let queues = model.status?.cupsQueues, !queues.isEmpty {
                    Text("Print queue: \(queues.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@main
struct DeskJet1050ScanApp: App {
    var body: some Scene {
        WindowGroup("DeskJet 1050 Scan") {
            ContentView()
        }
        .defaultSize(width: 560, height: 520)
    }
}
