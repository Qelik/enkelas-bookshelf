// Lift the subject out of a photograph and write a transparent PNG.
//
//     swift ios/Tools/cutout.swift <input> <output.png> [maxHeight]
//
// Shelf objects sit on a dark wooden case, so a photo with its background
// still attached reads as a white brick. Vision's foreground-instance mask is
// the same subject-lifting Photos uses for "remove background" — good enough
// on a well-lit object photographed against a plain wall, which is exactly
// what the public-domain museum and stock photos are.
//
// Trimmed to the subject's own bounds and scaled down afterwards: a 4000px
// museum scan is several megabytes for something drawn 40 points wide.
import AppKit
import CoreImage
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: cutout.swift <input> <output.png> [maxHeight]\n".utf8))
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let maxHeight = args.count > 3 ? (Double(args[3]) ?? 512) : 512

guard let source = CIImage(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("could not read \(inputURL.lastPathComponent)\n".utf8))
    exit(1)
}

let context = CIContext()
let handler = VNImageRequestHandler(ciImage: source)
let request = VNGenerateForegroundInstanceMaskRequest()

do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write(Data("vision failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

guard let result = request.results?.first else {
    FileHandle.standardError.write(Data("no subject found\n".utf8))
    exit(1)
}

// All instances, not just the largest: a potted plant is often reported as the
// pot and the foliage separately, and taking one loses half the object.
let maskedBuffer = try result.generateMaskedImage(
    ofInstances: result.allInstances,
    from: handler,
    croppedToInstancesExtent: true
)
var image = CIImage(cvPixelBuffer: maskedBuffer)

// Scale to the height the shelf actually draws, so the bundle isn't carrying
// museum resolution for a 40-point ornament.
let height = image.extent.height
if height > maxHeight {
    let scale = maxHeight / height
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
}

guard let cgImage = context.createCGImage(image, from: image.extent) else {
    FileHandle.standardError.write(Data("could not render\n".utf8))
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode png\n".utf8))
    exit(1)
}
try data.write(to: outputURL)
print("\(outputURL.lastPathComponent)  \(cgImage.width)x\(cgImage.height)  \(data.count / 1024) KB")
