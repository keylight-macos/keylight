import Foundation

enum VerificationError: Error, CustomStringConvertible {
    case usage
    case missingRecord(String)
    case invalidRecord(String)
    case mismatch(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: verify-dmg-finder-metadata.swift DS_STORE WIDTH HEIGHT ICON_SIZE TEXT_SIZE"
        case .missingRecord(let name):
            return "missing Finder metadata record: \(name)"
        case .invalidRecord(let name):
            return "invalid Finder metadata record: \(name)"
        case .mismatch(let message):
            return message
        }
    }
}

func record(named name: String, in data: Data) throws -> Data {
    let marker = Data(name.utf8)
    guard let markerRange = data.range(of: marker) else {
        throw VerificationError.missingRecord(name)
    }

    let lengthOffset = markerRange.upperBound
    guard lengthOffset + 4 <= data.count else {
        throw VerificationError.invalidRecord(name)
    }

    let length = data[lengthOffset..<(lengthOffset + 4)].reduce(0) {
        ($0 << 8) | Int($1)
    }
    let payloadOffset = lengthOffset + 4
    guard length > 0, payloadOffset + length <= data.count else {
        throw VerificationError.invalidRecord(name)
    }
    return data.subdata(in: payloadOffset..<(payloadOffset + length))
}

func dictionaryRecord(named name: String, in data: Data) throws -> [String: Any] {
    let payload = try record(named: name, in: data)
    let plist = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
    guard let dictionary = plist as? [String: Any] else {
        throw VerificationError.invalidRecord(name)
    }
    return dictionary
}

func requireFalse(_ key: String, in dictionary: [String: Any]) throws {
    guard let value = dictionary[key] as? Bool, value == false else {
        throw VerificationError.mismatch("Finder metadata \(key) must be false")
    }
}

func requireNumber(_ key: String, equals expected: Double, in dictionary: [String: Any]) throws {
    guard let number = dictionary[key] as? NSNumber,
          abs(number.doubleValue - expected) < 0.000_001 else {
        throw VerificationError.mismatch("Finder metadata \(key) must equal \(expected)")
    }
}

do {
    guard CommandLine.arguments.count == 6,
          let width = Int(CommandLine.arguments[2]),
          let height = Int(CommandLine.arguments[3]),
          let iconSize = Double(CommandLine.arguments[4]),
          let textSize = Double(CommandLine.arguments[5]) else {
        throw VerificationError.usage
    }

    let dsStoreURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let dsStore = try Data(contentsOf: dsStoreURL)
    let browser = try dictionaryRecord(named: ".bwspblob", in: dsStore)
    let iconView = try dictionaryRecord(named: ".icvpblob", in: dsStore)

    for key in ["ContainerShowSidebar", "ShowSidebar", "ShowStatusBar", "ShowTabView", "ShowToolbar"] {
        try requireFalse(key, in: browser)
    }

    guard let windowBounds = browser["WindowBounds"] as? String else {
        throw VerificationError.mismatch("Finder metadata WindowBounds is missing")
    }
    let escapedSize = NSRegularExpression.escapedPattern(for: "{\(width), \(height)}")
    let sizePattern = #"^\{\{-?\d+, -?\d+\}, \#(escapedSize)\}$"#
    guard windowBounds.range(of: sizePattern, options: .regularExpression) != nil else {
        throw VerificationError.mismatch(
            "Finder window bounds '\(windowBounds)' do not contain the expected \(width)×\(height) size"
        )
    }

    try requireNumber("iconSize", equals: iconSize, in: iconView)
    try requireNumber("textSize", equals: textSize, in: iconView)
    try requireNumber("backgroundType", equals: 2, in: iconView)
    guard iconView["arrangeBy"] as? String == "none" else {
        throw VerificationError.mismatch("Finder icon arrangement must be none")
    }
    guard iconView["labelOnBottom"] as? Bool == true else {
        throw VerificationError.mismatch("Finder icon labels must be below icons")
    }
    guard let backgroundAlias = iconView["backgroundImageAlias"] as? Data,
          !backgroundAlias.isEmpty else {
        throw VerificationError.mismatch("Finder background image alias is missing")
    }

    print("Finder metadata verified: \(width)×\(height), icons \(iconSize), labels \(textSize)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
