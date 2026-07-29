// Tools/LayoutLab/Sources/main.swift
// LayoutLab - Phase 4 tuning harness for Magic Layout (B32). Top-level
// executable Swift, same convention as Tests/SmokeTest.swift: only compiles
// as `main.swift`, linked directly against Sources/Engine/*.swift by
// `run.sh` via plain `swiftc` (no Xcode project, no simulator - Engine is
// platform-pure and Vision/CoreImage are fully available on macOS).
//
// For each set of 2-4 photos (grouped sequentially by filename - see
// `listPhotoSets`), this:
//   1. Loads the same 2000px-capped, orientation-corrected proxy
//      `PhotoLibraryService.loadForEditing` produces.
//   2. Runs the same two Vision requests, with the same bottom-left ->
//      top-left conversion, as `PhotoLibraryService.visionInputs(cgImage:)`.
//   3. Calls the REAL Engine entry points in the REAL order
//      `PickerView.buildDocument` uses: `mustKeepRegion` per photo, then
//      `faceAwareAssignment` for the decision, mirroring that function's own
//      DEBUG "previous vs new" comparison for the without-face-awareness
//      variant (`defaultTemplateIndex` + `contentFitAssignment`).
//   4. Renders a side-by-side contact-sheet PNG (`Render.swift`) and a
//      `summary.csv` row.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let argv = CommandLine.arguments
guard argv.count >= 3 else {
    fail("""
    Usage: layoutlab <photo-folder> <output-dir> [setSize=4]

    <photo-folder>  Folder of JPEG/HEIC/PNG photos.
    <output-dir>    Where sheet PNGs + summary.csv are written. Run via
                    run.sh, which supplies a safe (never-in-repo) default.
    [setSize]       2-4, default 4. See README for the grouping rule.
    """)
}

let photoFolder = argv[1]
let outputDirPath = argv[2]
let setSize: Int = {
    guard argv.count >= 4, let n = Int(argv[3]) else { return 4 }
    return max(2, min(4, n))
}()

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDirPath, withIntermediateDirectories: true)

let (sets, droppedCount) = listPhotoSets(in: photoFolder, setSize: setSize)
guard !sets.isEmpty else {
    fail("LayoutLab: no photo sets found in \(photoFolder) (need at least 2 photos of a supported type: \(supportedPhotoExtensions.sorted().joined(separator: ", ")))")
}
print("LayoutLab: \(sets.count) set(s), set size \(setSize), \(droppedCount) trailing photo(s) dropped (< 2 remaining).")

// A fresh collage's own border is genuinely zero (see buildDocument's own
// comment) - photos arrive touching, matching the app's own starting point,
// and matching it is what keeps `solve()`'s cell rects the same shape the
// real decision was scored against.
let border = BorderStyle(inner: 0, outer: 0, linked: true, cornerRadius: 0, color: .white)
// Decision canvas: proportions (all that `framingCost`/`contentFitAssignment`
// ever see) are scale-invariant, so this can be any square and match the
// app's own 1000x1000 exactly - kept identical to `buildDocument` rather than
// relying on that invariant silently.
let nominalCanvas = CGSize(width: 1000, height: 1000)

struct SummaryRow {
    var setName: String
    var fileNames: [String]
    var photoCount: Int
    var facesDetectedRaw: Int
    var facesKept: Int
    var defaultTemplateIndex: Int
    var faceAwareTemplateIndex: Int
    var faceAwareCost: Double
    var clippedDefault: Int
    var clippedFaceAware: Int
    var changed: Bool
}

var summaryRows: [SummaryRow] = []

for (setIndex, files) in sets.enumerated() {
    let setName = "set\(String(format: "%02d", setIndex + 1))"
    print("LayoutLab: \(setName) - \(files.map(\.lastPathComponent).joined(separator: ", "))")

    var order: [PhotoID] = []
    var photosByID: [PhotoID: PhotoData] = [:]
    var pixelSizes: [PhotoID: CGSize] = [:]
    var mustKeepRegions: [PhotoID: CGRect] = [:]
    var rawFaceCount = 0
    var keptFaceCount = 0
    var loadFailures: [String] = []

    for url in files {
        guard let (cgImage, pixelSize) = loadPhotoProxy(url: url) else {
            loadFailures.append(url.lastPathComponent)
            continue
        }
        let id = PhotoID()
        let vision = runVisionInputs(cgImage: cgImage)
        let kept = thresholdedFaces(faces: vision.faces.map(\.0), faceConfidences: vision.faces.map(\.1), photoPixelSize: pixelSize)
        rawFaceCount += vision.faces.count
        keptFaceCount += kept.count

        order.append(id)
        pixelSizes[id] = pixelSize
        photosByID[id] = PhotoData(id: id, cgImage: cgImage, pixelSize: pixelSize, vision: vision, survivingFaces: kept)

        if let region = mustKeepRegion(faces: vision.faces.map(\.0), faceConfidences: vision.faces.map(\.1), salientRegion: vision.salient, photoPixelSize: pixelSize) {
            mustKeepRegions[id] = region
        }
    }

    if !loadFailures.isEmpty {
        FileHandle.standardError.write("LayoutLab: \(setName) - failed to load \(loadFailures.joined(separator: ", "))\n".data(using: .utf8)!)
    }
    guard order.count >= 2 else {
        FileHandle.standardError.write("LayoutLab: \(setName) - fewer than 2 photos loaded, skipping\n".data(using: .utf8)!)
        continue
    }

    // ---- DECIDE, exactly as PickerView.buildDocument's PASS 2. ----------
    let decision = faceAwareAssignment(
        photos: order,
        photoSizes: pixelSizes,
        mustKeepRegions: mustKeepRegions,
        canvasSize: nominalCanvas,
        border: border
    )

    // ---- The WITHOUT-face-awareness variant - same computation
    // buildDocument's own DEBUG block runs for its before/after log line. ----
    let orientations = order.map { pixelSizes[$0] ?? CGSize(width: 1, height: 1) }
    let candidateTemplates = templates(for: order)
    let previousIndex = min(defaultTemplateIndex(orientations: orientations), candidateTemplates.count - 1)
    let previousAssigned = contentFitAssignment(
        photoSizes: pixelSizes,
        template: candidateTemplates[previousIndex],
        canvasSize: nominalCanvas,
        border: border
    )

    let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
    let previousOrder = photoIDs(in: previousAssigned).map { orderIndex[$0].map(String.init) ?? "?" }.joined(separator: ",")
    let newOrder = photoIDs(in: decision.template).map { orderIndex[$0].map(String.init) ?? "?" }.joined(separator: ",")
    let changed = previousIndex != decision.templateIndex || previousOrder != newOrder

    let outputURL = URL(fileURLWithPath: outputDirPath).appendingPathComponent("\(setName).png")
    let variants = [
        RenderVariant(label: "WITHOUT face-aware", template: previousAssigned, templateIndex: previousIndex, extra: ""),
        RenderVariant(label: "FACE-AWARE", template: decision.template, templateIndex: decision.templateIndex,
                      extra: String(format: " · cost %.3f", decision.cost))
    ]
    let panelResults = renderComparisonSheet(
        setLabel: setName,
        fileNames: files.map(\.lastPathComponent),
        photosByID: photosByID,
        variants: variants,
        border: border,
        outputURL: outputURL
    )
    let clippedDefault = panelResults.first?.clippedFaceCount ?? 0
    let clippedFaceAware = panelResults.count > 1 ? panelResults[1].clippedFaceCount : 0

    summaryRows.append(SummaryRow(
        setName: setName,
        fileNames: files.map(\.lastPathComponent),
        photoCount: order.count,
        facesDetectedRaw: rawFaceCount,
        facesKept: keptFaceCount,
        defaultTemplateIndex: previousIndex,
        faceAwareTemplateIndex: decision.templateIndex,
        faceAwareCost: decision.cost,
        clippedDefault: clippedDefault,
        clippedFaceAware: clippedFaceAware,
        changed: changed
    ))
}

// ---- summary.csv ----------------------------------------------------------
func csvField(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return s
}

var csv = "set,photos,files,faces_detected_raw,faces_kept,default_template_index,face_aware_template_index,face_aware_cost,faces_clipped_default,faces_clipped_face_aware,changed\n"
for row in summaryRows {
    csv += [
        row.setName,
        String(row.photoCount),
        csvField(row.fileNames.joined(separator: "; ")),
        String(row.facesDetectedRaw),
        String(row.facesKept),
        String(row.defaultTemplateIndex),
        String(row.faceAwareTemplateIndex),
        String(format: "%.4f", row.faceAwareCost),
        String(row.clippedDefault),
        String(row.clippedFaceAware),
        row.changed ? "yes" : "no"
    ].joined(separator: ",") + "\n"
}
let summaryURL = URL(fileURLWithPath: outputDirPath).appendingPathComponent("summary.csv")
try? csv.write(to: summaryURL, atomically: true, encoding: .utf8)

print("LayoutLab: wrote \(summaryRows.count) sheet(s) + summary.csv to \(outputDirPath)")
