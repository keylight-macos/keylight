import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum ConfigurationSnapshotFileError: LocalizedError {
    case invalidFilename
    case notRegularFile
    case fileSizeUnavailable
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidFilename:
            return String(
                localized: "Choose a .keylight-snapshot.json file."
            )
        case .notRegularFile:
            return String(localized: "Selected item is not a regular file.")
        case .fileSizeUnavailable:
            return String(localized: "Could not determine the file size.")
        case .fileTooLarge:
            return String(
                localized: "The snapshot file is too large (maximum 1 MB)."
            )
        }
    }
}

/// Keeps AppKit panel creation, lifetime, filename policy, and bounded file IO
/// out of SwiftUI. The returned nil value means the user cancelled.
@MainActor
final class ConfigurationSnapshotFilePanelHelper {
    static let filenameSuffix = ".keylight-snapshot.json"

    private var activeOpenPanel: NSOpenPanel?
    private var activeSavePanel: NSSavePanel?

    func chooseImportData() throws -> Data? {
        guard activeOpenPanel == nil else { return nil }
        let panel = NSOpenPanel()
        activeOpenPanel = panel
        defer { activeOpenPanel = nil }

        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = String(localized: "Import")

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        guard url.lastPathComponent.lowercased().hasSuffix(
            Self.filenameSuffix
        ) else {
            throw ConfigurationSnapshotFileError.invalidFilename
        }
        return try Self.readBoundedData(
            from: url,
            maximumSize: SettingsManager
                .maximumConfigurationSnapshotImportSize
        )
    }

    func export(
        _ data: Data,
        suggestedName: String
    ) throws -> URL? {
        guard activeSavePanel == nil else { return nil }
        let panel = NSSavePanel()
        activeSavePanel = panel
        defer { activeSavePanel = nil }

        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.exportFilename(
            for: suggestedName
        )
        panel.prompt = String(localized: "Export")

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }
        let url = Self.normalizedExportURL(selectedURL)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func exportFilename(for name: String) -> String {
        let characters = name.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "-_"))
            return allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(characters)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = sanitized.isEmpty ? "KeyLight-Snapshot" : sanitized
        return base + filenameSuffix
    }

    private static func normalizedExportURL(_ selectedURL: URL) -> URL {
        guard !selectedURL.lastPathComponent.lowercased().hasSuffix(
            filenameSuffix
        ) else {
            return selectedURL
        }
        let baseURL = selectedURL.pathExtension.lowercased() == "json"
            ? selectedURL.deletingPathExtension()
            : selectedURL
        return baseURL
            .appendingPathExtension("keylight-snapshot")
            .appendingPathExtension("json")
    }

    private static func readBoundedData(
        from url: URL,
        maximumSize: Int
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var fileStatus = stat()
        guard fstat(handle.fileDescriptor, &fileStatus) == 0,
              fileStatus.st_size >= 0 else {
            throw ConfigurationSnapshotFileError.fileSizeUnavailable
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigurationSnapshotFileError.notRegularFile
        }
        guard fileStatus.st_size <= Int64(maximumSize) else {
            throw ConfigurationSnapshotFileError.fileTooLarge
        }

        let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
        guard data.count <= maximumSize else {
            throw ConfigurationSnapshotFileError.fileTooLarge
        }
        return data
    }
}
