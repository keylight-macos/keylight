#!/usr/bin/env swift

import CryptoKit
import Foundation

private enum FixtureFailure: Error, LocalizedError {
    case unexpectedResult(label: String, output: String)

    var errorDescription: String? {
        switch self {
        case .unexpectedResult(let label, let output):
            return "\(label) produced the wrong verification result: \(output)"
        }
    }
}

private let scriptURL = URL(
    fileURLWithPath: CommandLine.arguments[0]
).standardizedFileURL
private let repositoryRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let verifier = repositoryRoot
    .appendingPathComponent("scripts/verify-sparkle-signature.swift")
private let fixtureRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("keylight-signature-verifier-\(UUID().uuidString)")
private let moduleCache = fixtureRoot.appendingPathComponent("module-cache")

try FileManager.default.createDirectory(
    at: moduleCache,
    withIntermediateDirectories: true
)
defer { try? FileManager.default.removeItem(at: fixtureRoot) }

private func runVerifier(
    _ arguments: [String],
    expectingSuccess: Bool,
    label: String
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", verifier.path] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["CLANG_MODULE_CACHE_PATH"] = moduleCache.path
    environment["SWIFT_MODULECACHE_PATH"] = moduleCache.path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let outputText = String(data: outputData, encoding: .utf8) ?? ""
    guard (process.terminationStatus == 0) == expectingSuccess else {
        throw FixtureFailure.unexpectedResult(
            label: label,
            output: outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

let privateKey = Curve25519.Signing.PrivateKey()
let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
let archive = Data("KeyLight signed update fixture\n".utf8)
let archiveSignature = try privateKey.signature(for: archive)
    .base64EncodedString()
let archiveURL = fixtureRoot.appendingPathComponent("archive.dmg")
try archive.write(to: archiveURL)

var tamperedArchive = archive
tamperedArchive[tamperedArchive.startIndex] ^= 1
let tamperedArchiveURL = fixtureRoot
    .appendingPathComponent("archive-tampered.dmg")
try tamperedArchive.write(to: tamperedArchiveURL)

let feedContent = Data(
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<rss version=\"2.0\"><channel><title>KeyLight Fixture</title></channel></rss>\n".utf8
)
let feedSignature = try privateKey.signature(for: feedContent)
    .base64EncodedString()
let feedBlock = Data(
    "<!-- sparkle-signatures:\nedSignature: \(feedSignature)\nlength: \(feedContent.count)\n-->\n".utf8
)
let feedURL = fixtureRoot.appendingPathComponent("appcast.xml")
try (feedContent + feedBlock).write(to: feedURL)

var tamperedFeed = feedContent
tamperedFeed[tamperedFeed.startIndex] ^= 1
let tamperedFeedURL = fixtureRoot
    .appendingPathComponent("appcast-tampered.xml")
try (tamperedFeed + feedBlock).write(to: tamperedFeedURL)
let unsignedFeedURL = fixtureRoot.appendingPathComponent("appcast-unsigned.xml")
try feedContent.write(to: unsignedFeedURL)

try runVerifier(
    [
        "archive", archiveURL.path, publicKey, archiveSignature,
        String(archive.count)
    ],
    expectingSuccess: true,
    label: "valid archive"
)
try runVerifier(
    ["appcast", feedURL.path, publicKey],
    expectingSuccess: true,
    label: "valid signed feed"
)
try runVerifier(
    [
        "archive", tamperedArchiveURL.path, publicKey, archiveSignature,
        String(archive.count)
    ],
    expectingSuccess: false,
    label: "tampered archive"
)
try runVerifier(
    ["appcast", tamperedFeedURL.path, publicKey],
    expectingSuccess: false,
    label: "tampered signed feed"
)
try runVerifier(
    ["appcast", unsignedFeedURL.path, publicKey],
    expectingSuccess: false,
    label: "unsigned feed"
)
try runVerifier(
    ["archive", archiveURL.path, publicKey, archiveSignature, "1"],
    expectingSuccess: false,
    label: "incorrect signed length"
)

print("Sparkle verifier accepts valid fixtures and rejects tampering.")
