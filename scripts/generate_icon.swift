import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Reproduce the approved icon from its committed master; never redraw or regenerate the design.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let master = root.appendingPathComponent("resources/branding/paidian-icon-master.png")
guard let source = CGImageSourceCreateWithURL(master as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
      original.width == original.height else { fatalError("图标母版必须是方形 PNG") }
let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.interpolationQuality = .high
context.draw(original, in: CGRect(x: 0, y: 0, width: size, height: size))
let folder = root.appendingPathComponent("PaiDian/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let output = folder.appendingPathComponent("AppIcon.png")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("无法写入图标") }
try Data(#"{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#.utf8)
    .write(to: folder.appendingPathComponent("Contents.json"))
print("Generated \(output.path)")
