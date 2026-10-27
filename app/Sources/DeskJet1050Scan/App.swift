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

enum ScanPass {
    case overview
    case detail
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
    var millimeters: CGSize {
        switch self {
        case .letter: CGSize(width: 215.9, height: 279.4)
        case .full: CGSize(width: 216, height: 297)
        case .a4: CGSize(width: 210, height: 297)
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
    @Published var scanProgress = 0
    @Published var cropping = true
    @Published var crop: CGRect?
    @Published var pageRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var pass: ScanPass = .overview

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
        return mode != scannedMode || paper != scannedPaper
    }

    var previewCaption: String {
        if scanning && pass == .overview {
            return scanProgress > 0
                ? "Quick 75 DPI look. \(scanProgress)% of the page is visible."
                : "Quick 75 DPI look. The first 10% will show in a moment."
        }
        if scanning {
            return scanProgress > 0
                ? "Scanning the box at \(dpi) DPI. \(scanProgress)% is visible."
                : "Scanning the box at \(dpi) DPI."
        }
        guard previewJPEG != nil else {
            return "The first scan is a fast 75 DPI look. Drag a box, then scan that box at \(dpi) DPI."
        }
        if pass == .detail {
            if crop != nil {
                return "Drag adjusts the crop. Save writes this \(scannedDPI ?? dpi) DPI image. Save crop writes only the box."
            }
            return "This is the \(scannedDPI ?? dpi) DPI scan. Drag a box if you want to save only part of it."
        }
        if crop != nil {
            return "Box selected. Scan it at \(dpi) DPI, or save just that box from this 75 DPI look."
        }
        return "Drag a box around the part you want. Then scan that box at \(dpi) DPI."
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

    func scanOverview() {
        pass = .overview
        pageRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
        crop = nil
        log = "Scanning a quick 75 DPI look in \(mode.title). Keep the lid closed."
        startScan(dpi: 75, region: nil, fileName: "DeskJet1050-preview.jpg", keepPreview: false, onSuccess: {}, onFailure: {})
    }

    func scanSelection() {
        guard let crop else {
            log = "Drag a box on the preview first."
            return
        }
        if let scannedPaper, scannedPaper != paper {
            log = "The page size changed. Run the 75 DPI preview again."
            return
        }
        let mapped = CGRect(
            x: pageRegion.minX + crop.minX * pageRegion.width,
            y: pageRegion.minY + crop.minY * pageRegion.height,
            width: crop.width * pageRegion.width,
            height: crop.height * pageRegion.height
        )
        guard mapped.width >= 0.02, mapped.height >= 0.02 else {
            log = "That box is too small to scan."
            return
        }
        let previousRegion = pageRegion
        pass = .detail
        self.crop = nil
        log = "Scanning the box in \(mode.title) at \(dpi) DPI. Keep the lid closed."
        startScan(
            dpi: dpi,
            region: regionArgument(mapped),
            fileName: "DeskJet1050-detail.jpg",
            keepPreview: true,
            onSuccess: { self.pageRegion = mapped },
            onFailure: {
                self.pass = .overview
                self.pageRegion = previousRegion
            }
        )
    }

    private func regionArgument(_ unit: CGRect) -> String {
        let page = (scannedPaper ?? paper).millimeters
        return String(
            format: "%.2f,%.2f,%.2f,%.2f",
            unit.minX * page.width,
            unit.minY * page.height,
            unit.maxX * page.width,
            unit.maxY * page.height
        )
    }

    private func startScan(
        dpi scanDPI: Int,
        region: String?,
        fileName: String,
        keepPreview: Bool,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping () -> Void
    ) {
        scanning = true
        scanProgress = 0
        if !keepPreview {
            preview = nil
            previewJPEG = nil
            rotation = 0
            brightness = 0
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        var args = [
            "scan",
            "--dpi", String(scanDPI),
            "--mode", mode.rawValue,
            "--paper", paper.rawValue,
            "--format", "jpeg",
            "--output", file.path,
            "--no-open",
            "--progress",
        ]
        if let region {
            args.append(contentsOf: ["--region", region])
        }
        let requestedMode = mode
        let requestedPaper = paper
        let requestedPass = pass
        Task {
            let (code, text) = await Self.runLines(binary, args) { line in
                self.takeScanLine(line)
            }
            scanning = false
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code == 0, let data = try? Data(contentsOf: file), data.count > 100 else {
                onFailure()
                log = trimmed.isEmpty ? "The scan did not produce an image." : trimmed
                return
            }
            onSuccess()
            previewJPEG = data
            scannedMode = requestedMode
            scannedDPI = scanDPI
            scannedPaper = requestedPaper
            pass = requestedPass
            scanProgress = 100
            rebuildPreview()
            if requestedPass == .overview {
                log = "75 DPI look is ready. Drag a box in the large preview, then scan it at \(dpi) DPI."
            } else {
                log = "\(scanDPI) DPI scan of the box is ready. Save it, or drag a tighter box and save the crop."
            }
        }
    }

    private func takeScanLine(_ line: String) {
        guard line.hasPrefix("PROGRESS:") else { return }
        let payload = line.dropFirst("PROGRESS:".count)
        let pieces = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let percent = Int(pieces[0]) else { return }
        let path = String(pieces[1])
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 100 else { return }
        previewJPEG = data
        scanProgress = percent
        rebuildPreview()
        log = "\(percent)% of the page is in the preview."
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

    func saveCrop() {
        guard let crop, let full = renderedCGImage(maxSide: nil) else { return }
        let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        let rect = CGRect(
            x: crop.origin.x * bounds.width,
            y: crop.origin.y * bounds.height,
            width: crop.width * bounds.width,
            height: crop.height * bounds.height
        ).integral.intersection(bounds)
        guard rect.width >= 2, rect.height >= 2, let cropped = full.cropping(to: rect) else { return }
        let panel = NSSavePanel()
        let types = [format.contentType] + ScanFormat.allCases.map(\.contentType).filter { $0 != format.contentType }
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "DeskJet1050-crop-\(Self.stamp()).\(format.ext)"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.title = "Save crop"
        panel.prompt = "Save crop"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chosen = ScanFormat.from(url: url) ?? format
        do {
            let data = try encoded(cropped, as: chosen, media: cropMedia(crop))
            try data.write(to: url, options: .atomic)
            format = chosen
            log = "Saved the crop as \(chosen.title). The full page is still here for Save."
            NSWorkspace.shared.open(url)
        } catch {
            log = error.localizedDescription
        }
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
            let data = try encoded(cgImage, as: chosen, media: fullMedia())
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

    private func fullMedia() -> CGSize {
        var size = (scannedPaper ?? paper).points
        size = CGSize(width: size.width * pageRegion.width, height: size.height * pageRegion.height)
        if ((rotation % 2) + 2) % 2 == 1 {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
    }

    private func cropMedia(_ crop: CGRect) -> CGSize {
        let page = fullMedia()
        return CGSize(width: max(page.width * crop.width, 36), height: max(page.height * crop.height, 36))
    }

    private func encoded(_ image: CGImage, as format: ScanFormat, media: CGSize) throws -> Data {
        if format == .pdf {
            guard let data = pdfData(image, media: media) else {
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

    private func pdfData(_ image: CGImage, media size: CGSize) -> Data? {
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

    private static func runLines(
        _ binary: String,
        _ args: [String],
        onLine: @escaping @MainActor (String) -> Void
    ) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:" + (environment["PATH"] ?? "")
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = LineBuffer()
            let queue = DispatchQueue(label: "dj1050.scan.lines")
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { file in
                let chunk = file.availableData
                guard !chunk.isEmpty else { return }
                queue.async {
                    let lines = buffer.append(chunk)
                    for line in lines {
                        Task { @MainActor in onLine(line) }
                    }
                }
            }
            process.terminationHandler = { finished in
                handle.readabilityHandler = nil
                queue.async {
                    let lines = buffer.append(handle.readDataToEndOfFile(), flush: true)
                    let text = buffer.text
                    let code = finished.terminationStatus
                    Task { @MainActor in
                        for line in lines { onLine(line) }
                        continuation.resume(returning: (code, text))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (1, error.localizedDescription))
            }
        }
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

private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private(set) var text = ""

    func append(_ chunk: Data, flush: Bool = false) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let row = pending.prefix(upTo: newline)
            pending.removeSubrange(0...newline)
            let line = String(data: Data(row), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text += line + "\n"
            if !line.isEmpty { lines.append(line) }
        }
        if flush, !pending.isEmpty {
            let line = String(data: pending, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pending.removeAll()
            if !line.isEmpty {
                text += line
                lines.append(line)
            }
        }
        return lines
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: ScannerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A fast 75 DPI look opens in a large window. Drag a box there, then scan that box at the detail resolution.")
                .foregroundStyle(.secondary)

            statusCard
            outputTypeRow
            fileTypeRow

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Detail")
                    Picker("Detail resolution", selection: $model.dpi) {
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

            Text("The first pass is always 75 DPI. Detail is the resolution used for the box you draw.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Refresh") { model.refresh() }
                    .disabled(model.scanning)
                Button("Image Capture") { model.showInImageCapture() }
                    .disabled(model.scanning)
                Button("Show preview") { openWindow(id: "scan-preview") }
                    .disabled(model.preview == nil && !model.scanning)
                Spacer()
                Button(model.scanning ? "Scanning…" : "Preview at 75 DPI") {
                    openWindow(id: "scan-preview")
                    model.scanOverview()
                }
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
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
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
                Text("Colour or page size changed. Run the 75 DPI preview again before scanning a box.")
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

struct LargePreviewScreen: View {
    @EnvironmentObject private var model: ScannerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.previewCaption)
                .font(.title3)
            ScanCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.35)))
            HStack {
                Button("Rotate left") { model.rotate(by: -1) }
                Button("Rotate right") { model.rotate(by: 1) }
                Button("Lighter") { model.lighten() }
                Button("Darker") { model.darken() }
                Button("Reset") { model.resetAdjustments() }
                Button("Clear box") { model.crop = nil }
                    .disabled(model.crop == nil)
                Spacer()
                Button("Scan box at \(model.dpi) DPI") { model.scanSelection() }
                    .disabled(model.scanning || model.crop == nil || model.preview == nil)
                Button("Save crop") { model.saveCrop() }
                    .disabled(model.scanning || model.crop == nil || model.preview == nil)
                Button("Save as \(model.format.title)") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.scanning || model.preview == nil)
            }
            .disabled(model.preview == nil && !model.scanning)
            Text(model.log)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .padding(20)
        .frame(minWidth: 1080, minHeight: 820)
    }
}

struct ScanCanvas: View {
    @ObservedObject var model: ScannerModel

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(image: model.preview?.size ?? NSSize(width: 1, height: 1), in: geo.size, inset: 16)
            let shown = model.scanning && model.scanProgress > 0 && model.scanProgress < 100
                ? CGRect(x: fitted.minX, y: 16, width: fitted.width, height: max(fitted.height, 8))
                : fitted
            ZStack(alignment: .top) {
                Color.white
                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(width: shown.width, height: shown.height)
                        .position(x: shown.midX, y: shown.midY)
                    if let crop = model.crop, !model.scanning {
                        Rectangle()
                            .stroke(Color.accentColor, lineWidth: 3)
                            .background(Color.accentColor.opacity(0.16))
                            .frame(width: crop.width * fitted.width, height: crop.height * fitted.height)
                            .position(
                                x: fitted.minX + crop.midX * fitted.width,
                                y: fitted.minY + crop.midY * fitted.height
                            )
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.viewfinder")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text(model.scanning ? "Waiting for the first 10% of the page." : "The scan will show here, large enough to crop.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: geo.size))
        }
    }

    private func drag(in container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !model.scanning, let image = model.preview else { return }
                let fitted = fittedRect(image: image.size, in: container, inset: 16)
                let start = unitPoint(value.startLocation, in: fitted)
                let end = unitPoint(value.location, in: fitted)
                let rect = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                )
                if rect.width >= 0.02 && rect.height >= 0.02 {
                    model.crop = rect
                }
            }
    }
}

private func fittedRect(image: NSSize, in container: CGSize, inset: CGFloat) -> CGRect {
    let box = CGRect(
        x: inset,
        y: inset,
        width: max(container.width - inset * 2, 1),
        height: max(container.height - inset * 2, 1)
    )
    guard image.width > 0, image.height > 0 else { return box }
    let scale = min(box.width / image.width, box.height / image.height)
    let size = CGSize(width: image.width * scale, height: image.height * scale)
    return CGRect(
        x: box.minX + (box.width - size.width) / 2,
        y: box.minY + (box.height - size.height) / 2,
        width: size.width,
        height: size.height
    )
}

private func unitPoint(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
    guard fitted.width > 0, fitted.height > 0 else { return .zero }
    let x = min(max((point.x - fitted.minX) / fitted.width, 0), 1)
    let y = min(max((point.y - fitted.minY) / fitted.height, 0), 1)
    return CGPoint(x: x, y: y)
}

@main
struct DeskJet1050ScanApp: App {
    @StateObject private var model = ScannerModel()

    var body: some Scene {
        WindowGroup("DeskJet 1050 Scan") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 760, height: 640)

        Window("Scan preview", id: "scan-preview") {
            LargePreviewScreen()
                .environmentObject(model)
        }
        .defaultSize(width: 1200, height: 900)
    }
}
