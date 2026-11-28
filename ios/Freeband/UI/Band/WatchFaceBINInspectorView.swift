import SwiftUI
import CoreFoundation
import CoreGraphics
import UIKit

/// Detailed, read-only BIN report. Export actions write copies to a temporary folder;
/// the imported source data is never modified.
struct WatchFaceBINInspectorView: View {
    let data: Data
    let inspection: WatchFaceBINInspection

    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItem?
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "File size"), value: data.count.formatted(.byteCount(style: .file)))
                LabeledContent(String(localized: "Signature"), value: inspection.header.signature)
                LabeledContent(String(localized: "Face ID"), value: inspection.header.id)
                LabeledContent(String(localized: "Name"), value: inspection.header.name)
                LabeledContent(String(localized: "Face records"), value: String(inspection.header.faceCount))
                LabeledContent(String(localized: "Style count"), value: String(inspection.header.styleCount))
                LabeledContent(String(localized: "Face layout"), value: inspection.header.faceLayout)
                LabeledContent(String(localized: "Preview offset"), value: String(format: "0x%08X", inspection.header.previewOffset))
            } header: {
                Text("BIN header")
            }

            Section {
                LabeledContent(String(localized: "Elements"), value: String(inspection.elementCount))
                LabeledContent(String(localized: "Widgets"), value: String(inspection.widgetCount))
                LabeledContent(String(localized: "Image resources"), value: String(inspection.imageCount))
                Text(inspection.resourceEncodingSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Structure summary")
            }

            ForEach(inspection.faces) { face in
                Section {
                    LabeledContent(String(localized: "Header offset"), value: String(format: "0x%08X", face.headerOffset))
                    if let name = face.name {
                        LabeledContent(String(localized: "Face name"), value: name)
                    }
                    LabeledContent(String(localized: "Face role"), value: face.role)
                    ForEach(face.tables) { table in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(table.name)
                                Spacer()
                                Text("\(table.count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Text(String(format: "offset 0x%08X · %@", table.offset, table.isValid ? "valid" : "invalid"))
                                .font(.caption.monospaced())
                                .foregroundStyle(table.isValid ? Color.secondary : Color.red)
                        }
                    }
                } header: {
                    Text(String.localizedStringWithFormat(String(localized: "Face %lld"), Int64(face.id + 1)))
                }
            }

            ForEach(inspection.faces) { face in
                if !face.elements.isEmpty {
                    Section {
                        ForEach(face.elements.prefix(250)) { element in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("Element \(element.id)")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("X \(element.x) · Y \(element.y)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text("Ref \(element.reference) · type \(element.referenceType) (\(referenceName(element.referenceType)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let widgetType = element.widgetType {
                                    Text(widgetType)
                                        .font(.caption)
                                }
                                if let dataSource = element.dataSource {
                                    Text("Data source: \(dataSource)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if face.elements.count > 250 {
                            Text("Only the first 250 elements are shown here. The JSON export contains the complete parsed list.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(String.localizedStringWithFormat(String(localized: "Face %lld elements"), Int64(face.id + 1)))
                    }
                }
            }

            Section {
                ForEach(inspection.faces.flatMap(\.images)) { image in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(image.table == 2 ? "Image" : "Image list") #\(image.index)")
                            .font(.subheadline.weight(.medium))
                        Text("\(image.width ?? 0) × \(image.height ?? 0) · \(image.encoding) · \(image.length.formatted(.byteCount(style: .file)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let frameCount = image.frameCount {
                            Text("Frames: \(frameCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Image resources")
            }

            if !inspection.unknownBlocks.isEmpty {
                Section {
                    LabeledContent(String(localized: "Unknown blocks"), value: String(inspection.unknownBlocks.count))
                    LabeledContent(String(localized: "Preserved raw bytes"), value: inspection.unknownBlocks.reduce(0) { $0 + $1.raw.count }.formatted(.byteCount(style: .file)))
                    Text("Unknown resource bytes are retained verbatim in the JSON export as Base64. They are not interpreted or rewritten.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Unknown data")
                }
            }

            if !inspection.issues.isEmpty {
                Section {
                    ForEach(Array(inspection.issues.prefix(30).enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if inspection.issues.count > 30 {
                        Text("The JSON export contains all \(inspection.issues.count) issue records.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Parser findings")
                }
            }

            Section {
                Button {
                    exportJSON()
                } label: {
                    Label(String(localized: "Export inspection JSON"), systemImage: "doc.text")
                }
                Button {
                    exportPNGs()
                } label: {
                    Label(String(localized: "Export decoded images as PNG"), systemImage: "photo")
                }
                .disabled(!hasDecodableImages)
                if let exportError {
                    Text(exportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Inspection is read-only. Exported files are generated separately; the original BIN remains unchanged.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "BIN Inspector"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .sheet(item: $share) { ActivitySheet(items: $0.urls) }
    }

    private var hasDecodableImages: Bool {
        MiWatchFacePreview.decode(data) != nil ||
            inspection.faces.flatMap(\.images).contains { resource in
                resource.isValid && resource.offset >= 0 && resource.length > 0
            }
    }

    private func referenceName(_ type: Int) -> String {
        switch type {
        case 2: return "image"
        case 4: return "animation"
        case 5: return "JavaScript"
        case 7: return "widget"
        case 8: return "editable"
        case 9: return "extended"
        default: return "unknown"
        }
    }

    private func exportJSON() {
        do {
            let folder = try exportFolder()
            let url = folder.appendingPathComponent("watch-face-inspection.json")
            try inspection.jsonData().write(to: url, options: .atomic)
            share = ShareItem(urls: [url])
            exportError = nil
        } catch {
            exportError = String(localized: "Couldn't export JSON: ") + error.localizedDescription
        }
    }

    private func exportPNGs() {
        do {
            let folder = try exportFolder()
            var urls: [URL] = []
            if let preview = MiWatchFacePreview.decode(data),
               let image = makeImage(preview), let bytes = image.pngData() {
                let url = folder.appendingPathComponent("preview.png")
                try bytes.write(to: url, options: .atomic)
                urls.append(url)
            }

            for face in inspection.faces {
                for resource in face.images where resource.isValid {
                    guard resource.offset >= 0, resource.length > 0,
                          resource.offset <= data.count,
                          resource.length <= data.count - resource.offset else { continue }
                    let block = data.subdata(in: resource.offset..<(resource.offset + resource.length))
                    let decoded = resource.table == 2
                        ? [MiWatchFacePreview.decodeBlock(block)].compactMap { $0 }
                        : MiWatchFacePreview.decodeImageListBlock(block)
                    for (frameIndex, frame) in decoded.enumerated() {
                        guard let image = makeImage(frame), let bytes = image.pngData() else { continue }
                        let filename = "face-\(face.id + 1)-\(resource.table == 2 ? "image" : "list")-\(resource.index)-\(frameIndex + 1).png"
                        let url = folder.appendingPathComponent(filename)
                        try bytes.write(to: url, options: .atomic)
                        urls.append(url)
                    }
                }
            }
            guard !urls.isEmpty else {
                exportError = String(localized: "No image resources could be decoded.")
                return
            }
            share = ShareItem(urls: urls)
            exportError = nil
        } catch {
            exportError = String(localized: "Couldn't export PNG images: ") + error.localizedDescription
        }
    }

    private func exportFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeband-bin-inspector", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeImage(_ preview: MiWatchFacePreview) -> UIImage? {
        let bytes = [UInt8](preview.rgba)
        guard bytes.count == preview.width * preview.height * 4,
              let providerData = bytes.withUnsafeBufferPointer({
                  CFDataCreate(kCFAllocatorDefault, $0.baseAddress, $0.count)
              }),
              let provider = CGDataProvider(data: providerData),
              let image = CGImage(width: preview.width, height: preview.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: preview.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }
}
