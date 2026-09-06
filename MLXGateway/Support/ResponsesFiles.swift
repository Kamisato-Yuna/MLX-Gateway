import Foundation
import AppKit
import PDFKit

/// Only client-supplied inline bytes are read. No local path or remote file lookup.
enum ResponsesFiles {
    static func parts(_ item: [String: Any], vision: Bool) throws -> [[String: Any]] {
        try ResponsesAdapter.keys(item, ["type", "filename", "file_data"], "input.content")
        guard let filename = item["filename"] as? String, !filename.isEmpty, filename.count <= 255,
              !filename.contains("/"), !filename.contains("\\"),
              let encoded = item["file_data"] as? String else {
            throw ResponsesAdapter.invalid("Inline files require a filename and base64 file_data. Hosted file IDs and file URLs are unavailable.", "input.content")
        }
        var payload = encoded
        var mediaType: String?
        if encoded.hasPrefix("data:") {
            guard let comma = encoded.firstIndex(of: ","), encoded[..<comma].hasSuffix(";base64") else {
                throw ResponsesAdapter.invalid("Expected a base64 data URL.", "input.content.file_data")
            }
            mediaType = String(encoded[encoded.index(encoded.startIndex, offsetBy: 5)..<comma]).replacingOccurrences(of: ";base64", with: "")
            payload = String(encoded[encoded.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: payload), !data.isEmpty, data.count <= 8 * 1024 * 1024 else {
            throw ResponsesAdapter.invalid("Invalid base64 or file exceeds 8 MiB.", "input.content.file_data")
        }
        if data.starts(with: Data("%PDF-".utf8)) || mediaType == "application/pdf" || filename.lowercased().hasSuffix(".pdf") {
            guard vision else { throw ResponsesAdapter.unsupported("PDF input requires mlx_vlm so page images are preserved alongside text.", "input.content") }
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
                throw ResponsesAdapter.invalid("Cannot read this PDF or it requires a password.", "input.content.file_data")
            }
            guard document.pageCount <= 20 else { throw ResponsesAdapter.unsupported("Inline PDFs are limited to 20 pages; split the document before sending.", "input.content.file_data") }
            var parts: [[String: Any]] = []
            var renderedBytes = 0
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { throw ResponsesAdapter.invalid("Cannot read a PDF page.", "input.content.file_data") }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else {
                    throw ResponsesAdapter.invalid("Invalid PDF page size.", "input.content.file_data")
                }
                let scale = min(1, 1536 / max(bounds.width, bounds.height))
                let size = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
                let image = page.thumbnail(of: size, for: .mediaBox)
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw ResponsesAdapter.invalid("Cannot render a PDF page.", "input.content.file_data")
                }
                renderedBytes += png.count
                guard renderedBytes <= 16 * 1024 * 1024 else { throw ResponsesAdapter.unsupported("Rendered PDF exceeds 16 MiB; split the document before sending.", "input.content.file_data") }
                parts.append(["type": "text", "text": "File: \(filename), page \(index + 1)\n" + (page.string ?? "")])
                parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]])
            }
            return parts
        }
        guard mediaType == nil || mediaType?.hasPrefix("text/") == true || ["application/json", "application/xml", "application/yaml"].contains(mediaType!),
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw ResponsesAdapter.unsupported("Only UTF-8 text files and PDFs are supported; binary office, audio and video files are unavailable.", "input.content.file_data")
        }
        return [["type": "text", "text": "File: \(filename)\n" + text]]
    }
}
