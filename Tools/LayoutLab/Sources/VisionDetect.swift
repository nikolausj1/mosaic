// Tools/LayoutLab/Sources/VisionDetect.swift
// Runs the SAME two Vision requests, on the SAME proxy image, with the SAME
// bottom-left -> top-left conversion as
// `Sources/App/Library/PhotoLibraryService.swift`'s `visionInputs(cgImage:)`.
// A mismatch here would make every downstream face rect and mustKeepRegion
// lie about where the app itself thinks faces are - see that file's own
// comment on why the conversion is y' = 1 - y - h.
import Foundation
import Vision
#if canImport(CoreGraphics)
import CoreGraphics
#endif

func runVisionInputs(cgImage: CGImage) -> (faces: [(CGRect, Double)], salient: CGRect?) {
    let faceRequest = VNDetectFaceRectanglesRequest()
    let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

    do {
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([faceRequest, saliencyRequest])
    } catch {
        // Same CPU-only retry PhotoLibraryService carries for the simulator.
        // Real macOS hardware should never need it, but keeping the same
        // shape here means a mismatch would show up as a loud stderr line
        // instead of a silent "Vision found nothing" false negative.
        FileHandle.standardError.write("LayoutLab: Vision default path failed (\(error)) - retrying CPU-only\n".data(using: .utf8)!)
        faceRequest.usesCPUOnly = true
        saliencyRequest.usesCPUOnly = true
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([faceRequest, saliencyRequest])
        } catch {
            FileHandle.standardError.write("LayoutLab: Vision CPU-only retry failed: \(error)\n".data(using: .utf8)!)
            return ([], nil)
        }
    }

    let faces: [(CGRect, Double)] = (faceRequest.results ?? []).map { obs in
        (flipToTopLeft(obs.boundingBox), Double(obs.confidence))
    }

    var salient: CGRect?
    if let observation = saliencyRequest.results?.first,
       let object = observation.salientObjects?.first {
        salient = flipToTopLeft(object.boundingBox)
    }

    return (faces, salient)
}

/// Identical to `PhotoLibraryService.flipToTopLeft`: Vision's normalized
/// rects are bottom-left origin; the Engine's convention (mustKeepRegion,
/// autoFrame, framingCost) is top-left, y down.
func flipToTopLeft(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: 1 - r.minY - r.height, width: r.width, height: r.height)
}
