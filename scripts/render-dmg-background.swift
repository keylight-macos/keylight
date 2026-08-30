import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4,
      let scale = Int(CommandLine.arguments[3]),
      (1...2).contains(scale) else {
    fatalError("usage: render-dmg-background.swift INPUT_THUMBNAIL OUTPUT_PNG SCALE")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let pointWidth = 600
let pointHeight = 400
let pixelWidth = pointWidth * scale
let pixelHeight = pointHeight * scale
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
      sourceImage.width >= pixelWidth,
      sourceImage.height >= pixelHeight,
      let croppedImage = sourceImage.cropping(
        to: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
      ),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else {
    fatalError("Unable to create the opaque \(pixelWidth)×\(pixelHeight) background image")
}

context.setFillColor(CGColor(red: 0.933, green: 0.957, blue: 0.980, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
context.interpolationQuality = .high
context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

guard let renderedImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
    fatalError("Unable to create the PNG destination")
}

CGImageDestinationAddImage(destination, renderedImage, [
    kCGImagePropertyDPIWidth: 72 * scale,
    kCGImagePropertyDPIHeight: 72 * scale,
    kCGImagePropertyPNGDictionary: [:]
] as CFDictionary)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to write the PNG")
}
