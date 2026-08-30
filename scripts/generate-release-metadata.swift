#!/usr/bin/env swift

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 16 else {
    fail(
        "usage: generate-release-metadata.swift ARTIFACT_NAME ARTIFACT_SHA256 "
            + "PACKAGE_LOCK_SHA256 VERSION BUILD BUNDLE_ID COMMIT TAG XCODE_VERSION "
            + "RELEASE_MODE SIGNER_SHA1 TEAM_ID CHECKSUM_OUTPUT SBOM_OUTPUT PROVENANCE_OUTPUT"
    )
}

let artifactName = arguments[1]
let artifactSHA256 = arguments[2]
let packageLockSHA256 = arguments[3]
let version = arguments[4]
let build = arguments[5]
let bundleIdentifier = arguments[6]
let commit = arguments[7]
let tag = arguments[8]
let xcodeVersion = arguments[9]
let releaseMode = arguments[10]
let signerSHA1 = arguments[11]
let teamID = arguments[12]
let checksumURL = URL(fileURLWithPath: arguments[13])
let sbomURL = URL(fileURLWithPath: arguments[14])
let provenanceURL = URL(fileURLWithPath: arguments[15])

guard releaseMode == "release" || releaseMode == "release-unsigned" else {
    fail("release mode must be release or release-unsigned")
}

guard artifactSHA256.range(
    of: #"^[a-f0-9]{64}$"#,
    options: .regularExpression
) != nil else {
    fail("artifact SHA-256 is malformed")
}
guard packageLockSHA256.range(
    of: #"^[a-f0-9]{64}$"#,
    options: .regularExpression
) != nil else {
    fail("Package.resolved SHA-256 is malformed")
}

let created = ISO8601DateFormatter().string(from: Date())
let documentNamespace =
    "https://github.com/keylight-macos/keylight/releases/tag/\(tag)/spdx/\(commit)"

let sbom: [String: Any] = [
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": "KeyLight-\(version)-SBOM",
    "documentNamespace": documentNamespace,
    "creationInfo": [
        "created": created,
        "creators": ["Tool: KeyLight verified release pipeline"]
    ],
    "packages": [
        [
            "name": "KeyLight",
            "SPDXID": "SPDXRef-Package-KeyLight",
            "versionInfo": version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": false,
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "NOASSERTION",
            "checksums": [[
                "algorithm": "SHA256",
                "checksumValue": artifactSHA256
            ]]
        ],
        [
            "name": "Sparkle",
            "SPDXID": "SPDXRef-Package-Sparkle",
            "versionInfo": "2.9.5",
            "downloadLocation": "https://github.com/sparkle-project/Sparkle",
            "filesAnalyzed": false,
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "NOASSERTION",
            "externalRefs": [[
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": "pkg:github/sparkle-project/Sparkle@2.9.5"
            ]]
        ]
    ],
    "relationships": [
        [
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": "SPDXRef-Package-KeyLight"
        ],
        [
            "spdxElementId": "SPDXRef-Package-KeyLight",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": "SPDXRef-Package-Sparkle"
        ]
    ]
]

let signing: [String: Any]
if releaseMode == "release" {
    signing = [
        "type": "Developer ID Application",
        "certificateSHA1": signerSHA1,
        "teamIdentifier": teamID,
        "hardenedRuntime": true,
        "notarized": true,
        "stapled": true,
        "sparkleEdDSA": true
    ]
} else {
    signing = [
        "type": "ad hoc",
        "certificateSHA1": "",
        "teamIdentifier": "not set",
        "hardenedRuntime": true,
        "notarized": false,
        "stapled": false,
        "sparkleEdDSA": false
    ]
}

let provenance: [String: Any] = [
    "schemaVersion": 1,
    "generatedAt": created,
    "source": [
        "repository": "https://github.com/keylight-macos/keylight",
        "commit": commit,
        "tag": tag,
        "dirty": false
    ],
    "build": [
        "xcode": xcodeVersion,
        "configuration": "Release",
        "architectures": ["arm64", "x86_64"],
        "minimumMacOS": "14.0",
        "packageResolvedSHA256": packageLockSHA256
    ],
    "application": [
        "version": version,
        "build": build,
        "bundleIdentifier": bundleIdentifier
    ],
    "artifact": [
        "name": artifactName,
        "sha256": artifactSHA256
    ],
    "signing": signing,
    "dependencies": [[
        "name": "Sparkle",
        "version": "2.9.5",
        "revision": "79bc9e872948e47877e76f194cb0c8e0412b0b90"
    ]]
]

let encoder = JSONSerialization.self
let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
let sbomData = try encoder.data(withJSONObject: sbom, options: options)
let provenanceData = try encoder.data(withJSONObject: provenance, options: options)
let checksumData = Data("\(artifactSHA256)  \(artifactName)\n".utf8)

do {
    try checksumData.write(to: checksumURL, options: .atomic)
    try sbomData.write(to: sbomURL, options: .atomic)
    try provenanceData.write(to: provenanceURL, options: .atomic)
} catch {
    fail("could not write release metadata: \(error.localizedDescription)")
}
