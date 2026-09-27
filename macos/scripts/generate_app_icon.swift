import AppKit
import CoreGraphics
import Foundation

/// Builds macOS compliant AppIcon.icns from source sketch artwork with transparent background.
func generateIcon(sourceImagePath: String, outputDir: String) {
    guard let srcImage = NSImage(contentsOfFile: sourceImagePath),
          let tiff = srcImage.tiffRepresentation,
          let srcRep = NSBitmapImageRep(data: tiff),
          let srcCG = srcRep.cgImage else {
        fatalError("Failed to load source image: \(sourceImagePath)")
    }

    // Crop the squircle artwork from source 1024x1024
    let cropRect = CGRect(x: 128, y: 128, width: 768, height: 768)
    guard let croppedCG = srcCG.cropping(to: cropRect) else {
        fatalError("Failed to crop squircle from source image")
    }

    // Target 1024x1024 RGBA transparent canvas
    let canvasSize = 1024
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: canvasSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create graphics context")
    }

    ctx.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

    // Standard macOS squircle grid: 824x824 centered inside 1024x1024 canvas
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185.0
    let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Primary drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 32, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.89, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Ambient contact shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.15))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.89, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle and draw cropped artwork
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()
    ctx.draw(croppedCG, in: iconRect)
    ctx.restoreGState()

    guard let outputCG = ctx.makeImage() else {
        fatalError("Failed to create master CGImage")
    }

    let masterRep = NSBitmapImageRep(cgImage: outputCG)
    guard let masterPNG = masterRep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to convert master image to PNG")
    }

    let masterPNGPath = "\(outputDir)/AppIcon.png"
    try? masterPNG.write(to: URL(fileURLWithPath: masterPNGPath))

    // Generate iconset
    let tempIconsetDir = "/tmp/TeslaCommander_Build.iconset"
    try? FileManager.default.removeItem(atPath: tempIconsetDir)
    try? FileManager.default.createDirectory(atPath: tempIconsetDir, withIntermediateDirectories: true)

    let targets: [(name: String, size: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    for target in targets {
        let size = target.size
        let destRect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let scaleCtx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { continue }

        scaleCtx.interpolationQuality = .high
        scaleCtx.draw(outputCG, in: destRect)

        if let scaledCG = scaleCtx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: scaledCG)
            if let pngData = rep.representation(using: .png, properties: [:]) {
                let outPath = "\(tempIconsetDir)/\(target.name)"
                try? pngData.write(to: URL(fileURLWithPath: outPath))
            }
        }
    }

    // Run iconutil
    let icnsPath = "\(outputDir)/AppIcon.icns"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", tempIconsetDir, "-o", icnsPath]
    try? process.run()
    process.waitUntilExit()

    print("Generated \(icnsPath) and \(masterPNGPath)")
}

let args = CommandLine.arguments
let source = args.count > 1 ? args[1] : "/Users/kamus/.gemini/antigravity/brain/ab5abffa-4ecf-471e-9faf-da8e61660ca9/tesla_sketch_icon_1790493851485.jpg"
let output = args.count > 2 ? args[2] : "macos/Sources/Resources"

generateIcon(sourceImagePath: source, outputDir: output)
