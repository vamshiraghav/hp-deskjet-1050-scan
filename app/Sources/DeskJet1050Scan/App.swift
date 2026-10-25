import AppKit
import CoreImage
import ImageIO
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

enum OutputType: String, CaseIterable, Identifiable {
    case color, gray, lineart

    var id: String { rawValue }
    var title: String {
        switch self {
        case .color: "Color"
        case .gray: "Grayscale"
        case .lineart: "Black and white"
        }
    }
    var detail: String {
        switch self {
        case .color: "Photos and coloured pages"
        case .gray: "Shades of gray"
        case .lineart: "Plain text"
        }
    }
}

enum ScanFormat: String, CaseIterable, Identifiable {
    case jpeg, pdf, png, tiff

    var id: String { rawValue }
    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .pdf: "PDF"
        case .png: "PNG"
        case .tiff: "TIFF"
        }
    }
    var ext: String {
        switch self {
        case .jpeg: "jpg"
        case .pdf: "pdf"
        case .png: "png"
        case .tiff: "tiff"
        }
    }
    var contentType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .pdf: .pdf
        case .png: .png
        case .tiff: .tiff
        }
    }

    static func from(url: URL) -> ScanFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "pdf": .pdf
        case "png": .png
        case "tif", "tiff": .tiff
        default: nil
        }
    }
}

enum PageSize: String, CaseIterable, Identifiable {
    case a4, letter, full

    var id: String { rawValue }
    var title: String {
        switch self {
        case .a4: "A4"
        case .letter: "Letter"
        case .full: "Full glass"
        }
    }
    var points: CGSize {
        switch self {
        case .letter: CGSize(width: 612, height: 792)
        case .full: CGSize(width: 216.0 / 25.4 * 72.0, height: 297.0 / 25.4 * 72.0)
        case .a4: CGSize(width: 595.276, height: 841.890)
        }
    }
}

@MainActor
final class ScannerModel: ObservableObject {
    @Published var status: ScannerStatus?
    @Published var dpi = 300
    @Published var mode: OutputType = .color
    @Published var paper: PageSize = .a4
    @Published var format: ScanFormat = .jpeg
    @Published var scanning = false
    @Published var log = "Checking the DeskJet 1050…"
    @Published var preview: NSImage?
    @Published var rotation = 0
    @Published var brightness: Float = 0

    let resolutions = [75, 100, 150, 200, 300, 600, 1200]
    private var previewJPEG: Data?
    private var scannedMode: OutputType?
    private var scannedDPI: Int?
    private var scannedPaper: PageSize?
    private let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
    ])

    var settingsStale: Bool {
        guard previewJPEG != nil else { return false }
        return mode != scannedMode || dpi != scannedDPI || paper != scannedPaper
    }

    var previewCaption: String {
        guard let scannedMode, let scannedDPI, let scannedPaper else {
            return "Scan the glass first. Color is the usual choice. Pick JPEG, PDF, PNG, or TIFF when you save."
        }
        return "Preview is \(scannedMode.title), \(scannedDPI) DPI, \(scannedPaper.title). Save it as \(format.title)."
    }

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
            if previewJPEG == nil {
                log = decoded.message
            }
        }
    }

    func scan() {
        scanning = true
        log = "Scanning the glass in \(mode.title) at \(dpi) DPI. Keep the lid closed."
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskJet1050-preview.jpg")
        let args = [
            "scan",
            "--dpi", String(dpi),
            "--mode", mode.rawValue,
            "--paper", paper.rawValue,
            "--format", "jpeg",
            "--output", file.path,
            "--no-open",
        ]
        let requestedMode = mode
        let requestedDPI = dpi
        let requestedPaper = paper
        Task {
            let (code, text) = await Self.run(binary, args)
            scanning = false
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code == 0, let data = try? Data(contentsOf: file), data.count > 100 else {
                log = trimmed.isEmpty ? "The scan did not produce an image." : trimmed
                return
            }
            previewJPEG = data
            scannedMode = requestedMode
            scannedDPI = requestedDPI
            scannedPaper = requestedPaper
            rotation = 0
            brightness = 0
            rebuildPreview()
            log = "Scan finished in \(requestedMode.title). Choose JPEG, PDF, PNG, or TIFF, then Save."
        }
    }

    func rotate(by turns: Int) {
        guard previewJPEG != nil else { return }
        rotation = (rotation + turns) % 4
        rebuildPreview()
    }

    func lighten() {
        guard previewJPEG != nil else { return }
        brightness = min(0.35, brightness + 0.06)
        rebuildPreview()
    }

    func darken() {
        guard previewJPEG != nil else { return }
        brightness = max(-0.35, brightness - 0.06)
        rebuildPreview()
    }

    func resetAdjustments() {
        rotation = 0
        brightness = 0
        rebuildPreview()
    }

    func save() {
        guard let cgImage = renderedCGImage(maxSide: nil) else { return }
        let panel = NSSavePanel()
        let types = [format.contentType] + ScanFormat.allCases.map(\.contentType).filter { $0 != format.contentType }
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "DeskJet1050-\(Self.stamp()).\(format.ext)"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.title = "Save scan"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chosen = ScanFormat.from(url: url) ?? format
        do {
            let data = try encoded(cgImage, as: chosen, paper: scannedPaper ?? paper, turns: rotation)
            try data.write(to: url, options: .atomic)
            format = chosen
            log = "Saved \(chosen.title) to \(url.path)"
            NSWorkspace.shared.open(url)
        } catch {
            log = error.localizedDescription
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

    private func rebuildPreview() {
        guard let cgImage = renderedCGImage(maxSide: 1400) else {
            preview = nil
            return
        }
        preview = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func renderedCGImage(maxSide: CGFloat?) -> CGImage? {
        guard let previewJPEG, var image = CIImage(data: previewJPEG) else { return nil }
        if scannedMode == .lineart {
            if let mono = CIFilter(name: "CIPhotoEffectMono") {
                mono.setValue(image, forKey: kCIInputImageKey)
                image = mono.outputImage ?? image
            }
            image = toned(image, saturation: 0, contrast: 6, brightness: 0)
        }
        if brightness != 0 {
            image = toned(image, saturation: 1, contrast: 1, brightness: brightness)
        }
        image = rotated(image, quarters: rotation)
        if let maxSide {
            let side = max(image.extent.width, image.extent.height)
            if side > maxSide {
                let scale = maxSide / side
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        return ciContext.createCGImage(image, from: image.extent.integral)
    }

    private func toned(_ image: CIImage, saturation: Float, contrast: Float, brightness: Float) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        return filter.outputImage ?? image
    }

    private func rotated(_ image: CIImage, quarters: Int) -> CIImage {
        let turns = ((quarters % 4) + 4) % 4
        guard turns != 0 else { return image }
        let angle = CGFloat(turns) * .pi / 2
        let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
        let spun = image.transformed(by: transform)
        let extent = spun.extent
        return spun.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
    }

    private func encoded(_ image: CGImage, as format: ScanFormat, paper: PageSize, turns: Int) throws -> Data {
        if format == .pdf {
            guard let data = pdfData(image, paper: paper, turns: turns) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.contentType.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }

    private func pdfData(_ image: CGImage, paper: PageSize, turns: Int) -> Data? {
        var size = paper.points
        if ((turns % 2) + 2) % 2 == 1 {
            size = CGSize(width: size.height, height: size.width)
        }
        var media = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            return nil
        }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: media)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan the glass, check the colour, then save as JPEG, PDF, PNG, or TIFF.")
                .foregroundStyle(.secondary)

            statusCard
            outputTypeRow
            fileTypeRow

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
                    Text("Page")
                    Picker("Page", selection: $model.paper) {
                        ForEach(PageSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
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
                Button("Save as \(model.format.title)") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.preview == nil || model.scanning)
                Button(model.scanning ? "Scanning…" : "Scan") { model.scan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.scanning || model.status?.ready != true)
            }

            previewPane

            HStack {
                Button("Rotate left") { model.rotate(by: -1) }
                Button("Rotate right") { model.rotate(by: 1) }
                Button("Lighter") { model.lighten() }
                Button("Darker") { model.darken() }
                Button("Reset") { model.resetAdjustments() }
                Spacer()
            }
            .disabled(model.preview == nil || model.scanning)

            Text(model.log)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 640)
        .onAppear { model.refresh() }
    }

    private var outputTypeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output type")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(OutputType.allCases) { type in
                    Button {
                        model.mode = type
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(type.title)
                                .font(.body.weight(.semibold))
                            Text(type.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(model.mode == type ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(model.mode == type ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: model.mode == type ? 2 : 1)
                    )
                }
            }
            if model.settingsStale {
                Text("Output type, resolution, or page size changed. Scan again to apply them. The file type is used when you save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fileTypeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File type")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(ScanFormat.allCases) { kind in
                    Button(kind.title) { model.format = kind }
                        .buttonStyle(.borderedProminent)
                        .tint(model.format == kind ? Color.accentColor : Color.secondary.opacity(0.45))
                }
            }
            Text("JPEG for photos, PDF for a document, PNG or TIFF when you want a lossless file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.previewCaption)
                .font(.callout)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.viewfinder")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("The page shows up here after Scan.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
        }
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
        .defaultSize(width: 760, height: 760)
    }
}
