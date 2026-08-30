#!/usr/bin/env swift

import CryptoKit
import Foundation

private enum VerificationError: Error, LocalizedError {
    case usage
    case invalidPublicKey
    case invalidSignature
    case invalidLength
    case unsignedFeed
    case malformedFeedSignature
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: verify-sparkle-signature.swift archive FILE PUBLIC_KEY_BASE64 SIGNATURE_BASE64 [EXPECTED_LENGTH] | appcast FILE PUBLIC_KEY_BASE64"
        case .invalidPublicKey:
            return "public key must be a base64-encoded 32-byte Ed25519 key"
        case .invalidSignature:
            return "signature must be a base64-encoded 64-byte Ed25519 signature"
        case .invalidLength:
            return "signed content length does not match"
        case .unsignedFeed:
            return "appcast does not contain a Sparkle signed-feed block"
        case .malformedFeedSignature:
            return "appcast signed-feed block is malformed"
        case .verificationFailed:
            return "Ed25519 signature verification failed"
        }
    }
}

private func decodedPublicKey(_ value: String) throws -> Curve25519.Signing.PublicKey {
    guard let data = Data(base64Encoded: value), data.count == 32 else {
        throw VerificationError.invalidPublicKey
    }
    return try Curve25519.Signing.PublicKey(rawRepresentation: data)
}

private func decodedSignature(_ value: String) throws -> Data {
    guard let data = Data(base64Encoded: value), data.count == 64 else {
        throw VerificationError.invalidSignature
    }
    return data
}

private func verify(
    data: Data,
    signatureValue: String,
    publicKeyValue: String,
    expectedLength: Int?
) throws {
    if let expectedLength, data.count != expectedLength {
        throw VerificationError.invalidLength
    }
    let publicKey = try decodedPublicKey(publicKeyValue)
    let signature = try decodedSignature(signatureValue)
    guard publicKey.isValidSignature(signature, for: data) else {
        throw VerificationError.verificationFailed
    }
}

private func verifyArchive(arguments: ArraySlice<String>) throws {
    guard arguments.count == 3 || arguments.count == 4 else {
        throw VerificationError.usage
    }
    let values = Array(arguments)
    let fileData = try Data(contentsOf: URL(fileURLWithPath: values[0]))
    let expectedLength: Int?
    if values.count == 4 {
        guard let parsed = Int(values[3]), parsed >= 0 else {
            throw VerificationError.invalidLength
        }
        expectedLength = parsed
    } else {
        expectedLength = nil
    }
    try verify(
        data: fileData,
        signatureValue: values[2],
        publicKeyValue: values[1],
        expectedLength: expectedLength
    )
}

private func verifyAppcast(arguments: ArraySlice<String>) throws {
    guard arguments.count == 2 else { throw VerificationError.usage }
    let values = Array(arguments)
    let appcastData = try Data(contentsOf: URL(fileURLWithPath: values[0]))
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let markerRange = appcastData.range(
        of: marker,
        options: .backwards
    ) else {
        throw VerificationError.unsignedFeed
    }

    let content = appcastData.subdata(in: appcastData.startIndex..<markerRange.lowerBound)
    let blockData = appcastData.subdata(in: markerRange.lowerBound..<appcastData.endIndex)
    guard let block = String(data: blockData, encoding: .utf8) else {
        throw VerificationError.malformedFeedSignature
    }
    let expression = try NSRegularExpression(
        pattern: #"^<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]+={0,2})\nlength: ([0-9]+)\n-->\n?$"#
    )
    let fullRange = NSRange(block.startIndex..<block.endIndex, in: block)
    guard let match = expression.firstMatch(
        in: block,
        options: [],
        range: fullRange
    ),
    match.range == fullRange,
    let signatureRange = Range(match.range(at: 1), in: block),
    let lengthRange = Range(match.range(at: 2), in: block),
    let expectedLength = Int(block[lengthRange]) else {
        throw VerificationError.malformedFeedSignature
    }
    try verify(
        data: content,
        signatureValue: String(block[signatureRange]),
        publicKeyValue: values[1],
        expectedLength: expectedLength
    )
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else { throw VerificationError.usage }
    switch arguments[1] {
    case "archive":
        try verifyArchive(arguments: arguments.dropFirst(2))
    case "appcast":
        try verifyAppcast(arguments: arguments.dropFirst(2))
    default:
        throw VerificationError.usage
    }
    print("Sparkle Ed25519 signature is valid.")
} catch {
    let message = (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}
