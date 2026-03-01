/// Winlink Attachment Support — Dateianhänge für Winlink-Nachrichten.
///
/// Unterstützt Bilder (mit Auto-Shrink für HF-Tauglichkeit), Text, PDF
/// und andere Dateitypen. Bilder werden automatisch auf eine für HF
/// akzeptable Größe komprimiert.
///
/// Maximale empfohlene Nachrichtengröße über HF: ~50 KB (komprimiert)
/// Über Telnet: ~120 KB (komprimiert)
///
/// Referenz: https://github.com/la5nta/pat (attachment handling)

import Foundation
import UIKit

// MARK: - Attachment Constants

/// Attachment-Limits und Konfiguration
enum WinlinkAttachmentConfig {
    /// Maximale Gesamtgröße aller Anhänge für HF-Übertragung (unkomprimiert)
    static let maxHFSize = 50_000
    /// Maximale Gesamtgröße für Telnet-Übertragung
    static let maxTelnetSize = 120_000
    /// Maximale Bildauflösung für HF (Breite × Höhe)
    static let maxHFImageWidth: CGFloat = 320
    static let maxHFImageHeight: CGFloat = 240
    /// Maximale Bildauflösung für Telnet
    static let maxTelnetImageWidth: CGFloat = 800
    static let maxTelnetImageHeight: CGFloat = 600
    /// JPEG-Qualität für HF
    static let hfJPEGQuality: CGFloat = 0.3
    /// JPEG-Qualität für Telnet
    static let telnetJPEGQuality: CGFloat = 0.6
    /// Erlaubte MIME-Types
    static let allowedMimeTypes = [
        "text/plain",
        "text/html",
        "image/jpeg",
        "image/png",
        "image/gif",
        "application/pdf",
        "application/octet-stream",
    ]
}

// MARK: - Attachment Builder

/// Erstellt und verarbeitet Anhänge für Winlink-Nachrichten.
///
/// Bilder werden automatisch verkleinert und komprimiert.
/// Andere Dateitypen werden unverändert angehängt.
final class WinlinkAttachmentBuilder {

    /// Transport-Modus beeinflusst die maximale Größe
    enum TransportMode {
        case hf      // ARDOP über Funk — strenge Limits
        case telnet  // Internet — größere Dateien erlaubt
    }

    private let transportMode: TransportMode

    init(mode: TransportMode = .hf) {
        self.transportMode = mode
    }

    // MARK: - Image Attachment

    /// Erstellt einen Bildanhang mit automatischer Größenanpassung.
    func createImageAttachment(
        image: UIImage,
        filename: String = "bild.jpg"
    ) -> WinlinkAttachment? {
        let maxWidth: CGFloat
        let maxHeight: CGFloat
        let quality: CGFloat

        switch transportMode {
        case .hf:
            maxWidth = WinlinkAttachmentConfig.maxHFImageWidth
            maxHeight = WinlinkAttachmentConfig.maxHFImageHeight
            quality = WinlinkAttachmentConfig.hfJPEGQuality
        case .telnet:
            maxWidth = WinlinkAttachmentConfig.maxTelnetImageWidth
            maxHeight = WinlinkAttachmentConfig.maxTelnetImageHeight
            quality = WinlinkAttachmentConfig.telnetJPEGQuality
        }

        // Resize if needed
        let resized = resizeImage(image, maxWidth: maxWidth, maxHeight: maxHeight)

        // Compress to JPEG
        guard let data = resized.jpegData(compressionQuality: quality) else {
            return nil
        }

        let name = filename.hasSuffix(".jpg") || filename.hasSuffix(".jpeg")
            ? filename
            : filename.replacingOccurrences(of: "\\.[^.]+$", with: ".jpg", options: .regularExpression)

        return WinlinkAttachment(
            filename: name,
            mimeType: "image/jpeg",
            data: data
        )
    }

    // MARK: - File Attachment

    /// Erstellt einen Anhang aus Dateidaten.
    func createFileAttachment(
        data: Data,
        filename: String,
        mimeType: String = "application/octet-stream"
    ) -> WinlinkAttachment? {
        let maxSize = transportMode == .hf
            ? WinlinkAttachmentConfig.maxHFSize
            : WinlinkAttachmentConfig.maxTelnetSize

        guard data.count <= maxSize else {
            return nil // Zu groß
        }

        return WinlinkAttachment(
            filename: filename,
            mimeType: mimeType,
            data: data
        )
    }

    /// Erstellt einen Textanhang.
    func createTextAttachment(
        text: String,
        filename: String = "anhang.txt"
    ) -> WinlinkAttachment {
        WinlinkAttachment(
            filename: filename,
            mimeType: "text/plain",
            data: Data(text.utf8)
        )
    }

    // MARK: - Validation

    /// Prüft ob die Gesamtgröße aller Anhänge im Limit liegt.
    func validateTotalSize(_ attachments: [WinlinkAttachment]) -> AttachmentValidation {
        let totalSize = attachments.reduce(0) { $0 + $1.data.count }
        let maxSize = transportMode == .hf
            ? WinlinkAttachmentConfig.maxHFSize
            : WinlinkAttachmentConfig.maxTelnetSize

        if totalSize <= maxSize {
            return .ok(totalSize: totalSize, maxSize: maxSize)
        } else {
            return .tooLarge(totalSize: totalSize, maxSize: maxSize)
        }
    }

    enum AttachmentValidation {
        case ok(totalSize: Int, maxSize: Int)
        case tooLarge(totalSize: Int, maxSize: Int)

        var isValid: Bool {
            switch self {
            case .ok: return true
            case .tooLarge: return false
            }
        }

        var message: String {
            switch self {
            case .ok(let total, let max):
                return "\(formatBytes(total)) / \(formatBytes(max))"
            case .tooLarge(let total, let max):
                return "Zu groß: \(formatBytes(total)) / \(formatBytes(max))"
            }
        }

        private func formatBytes(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    // MARK: - MIME Encoding

    /// Kodiert Anhänge als MIME multipart für B2F-Übertragung.
    static func encodeMIME(
        body: String,
        attachments: [WinlinkAttachment]
    ) -> (mimeType: String, data: Data) {
        guard !attachments.isEmpty else {
            return ("text/plain", Data(body.utf8))
        }

        let boundary = "----=_DigiFox_\(UUID().uuidString.prefix(8))"
        var mime = ""

        // Body part
        mime += "--\(boundary)\r\n"
        mime += "Content-Type: text/plain; charset=utf-8\r\n"
        mime += "Content-Transfer-Encoding: 7bit\r\n"
        mime += "\r\n"
        mime += body
        mime += "\r\n"

        // Attachment parts
        for attachment in attachments {
            mime += "--\(boundary)\r\n"
            mime += "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
            mime += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n"
            mime += "\r\n"
            mime += attachment.data.base64EncodedString(options: .lineLength76Characters)
            mime += "\r\n"
        }

        mime += "--\(boundary)--\r\n"

        return ("multipart/mixed; boundary=\"\(boundary)\"", Data(mime.utf8))
    }

    /// Dekodiert MIME multipart Anhänge.
    static func decodeMIME(data: Data, contentType: String) -> (body: String, attachments: [WinlinkAttachment]) {
        guard contentType.contains("multipart/mixed"),
              let boundaryRange = contentType.range(of: "boundary=\""),
              let endQuote = contentType[boundaryRange.upperBound...].firstIndex(of: "\"") else {
            return (String(data: data, encoding: .utf8) ?? "", [])
        }

        let boundary = String(contentType[boundaryRange.upperBound..<endQuote])
        let content = String(data: data, encoding: .utf8) ?? ""
        let parts = content.components(separatedBy: "--\(boundary)")

        var bodyText = ""
        var attachments: [WinlinkAttachment] = []

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" { continue }

            // Split headers and content
            let sections = trimmed.components(separatedBy: "\r\n\r\n")
            guard sections.count >= 2 else { continue }

            let headers = sections[0].lowercased()
            let content = sections.dropFirst().joined(separator: "\r\n\r\n")

            if headers.contains("content-disposition: attachment") {
                // Extract filename
                let filename: String
                if let fnRange = headers.range(of: "filename=\""),
                   let fnEnd = headers[fnRange.upperBound...].firstIndex(of: "\"") {
                    filename = String(headers[fnRange.upperBound..<fnEnd])
                } else {
                    filename = "anhang"
                }

                // Extract MIME type
                let mimeType: String
                if let ctRange = headers.range(of: "content-type: "),
                   let ctEnd = headers[ctRange.upperBound...].firstIndex(of: ";") ?? headers[ctRange.upperBound...].firstIndex(of: "\r") {
                    mimeType = String(headers[ctRange.upperBound..<ctEnd]).trimmingCharacters(in: .whitespaces)
                } else {
                    mimeType = "application/octet-stream"
                }

                // Decode base64 content
                let cleanContent = content.replacingOccurrences(of: "\r\n", with: "")
                if let data = Data(base64Encoded: cleanContent) {
                    attachments.append(WinlinkAttachment(
                        filename: filename,
                        mimeType: mimeType,
                        data: data
                    ))
                }
            } else {
                bodyText = content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return (bodyText, attachments)
    }

    // MARK: - Image Resizing

    private func resizeImage(_ image: UIImage, maxWidth: CGFloat, maxHeight: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > maxWidth || size.height > maxHeight else {
            return image
        }

        let widthRatio = maxWidth / size.width
        let heightRatio = maxHeight / size.height
        let ratio = min(widthRatio, heightRatio)

        let newSize = CGSize(
            width: size.width * ratio,
            height: size.height * ratio
        )

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
