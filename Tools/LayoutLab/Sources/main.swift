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

/// One row per PHOTO (not per set) - `summary.csv` only ever reported
/// faces_kept as a SET total, which can't tell a 6-person group photo with
/// a small cell apart from a 1-person selfie with a big one in the same
/// set. Added alongside (not replacing) `summary.csv` to judge the
/// group-photo-cell-size rule (B32 follow-up) against real photos: does the
/// photo with MORE (smaller) faces actually end up with MORE cell area.
struct PerPhotoRow {
    var setName: String
    var fileName: String
    var faceCount: Int
    var smallestFaceHeightFraction: Double?
    var defaultCellAreaFraction: Double
    var faceAwareCellAreaFraction: Double
}

var summaryRows: [SummaryRow] = []
var perPhotoRows: [PerPhotoRow] = []

for (setIndex, files) in sets.enumerated() {
    let setName = "set\(String(format: "%02d", setIndex + 1))"
    print("LayoutLab: \(setName) - \(files.map(\.lastPathComponent).joined(separator: ", "))")

    var order: [PhotoID] = []
    var photosByID: [PhotoID: PhotoData] = [:]
    var pixelSizes: [PhotoID: CGSize] = [:]
    var mustKeepRegions: [PhotoID: CGRect] = [:]
    // Group-photo-cell-size signal (see MagicLayout.swift's
    // `smallestSurvivingFaceHeight`) - per photo, computed from the SAME
    // surviving-faces list `kept` below already is, so this costs nothing
    // extra to gather here.
    var mustKeepFaceHeights: [PhotoID: Double] = [:]
    var fileNameByID: [PhotoID: String] = [:]
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
        fileNameByID[id] = url.lastPathComponent
        // Fix 1 verification: the ORIGINAL file's pixel dimensions, read
        // without decoding at full size (see `readSourcePixelSize`'s own
        // comment) - this is what makes the resolution-guard fix in
        // `AutoFrame.swift` actually visible in a LayoutLab run instead of
        // every photo still measuring as <=2000px against the proxy.
        let sourcePixelSize = readSourcePixelSize(url: url)
        photosByID[id] = PhotoData(id: id, cgImage: cgImage, pixelSize: pixelSize, sourcePixelSize: sourcePixelSize, vision: vision, survivingFaces: kept)

        if let region = mustKeepRegion(faces: vision.faces.map(\.0), faceConfidences: vision.faces.map(\.1), salientRegion: vision.salient, photoPixelSize: pixelSize) {
            mustKeepRegions[id] = region
        }
        if let smallest = smallestSurvivingFaceHeight(faces: vision.faces.map(\.0), faceConfidences: vision.faces.map(\.1), photoPixelSize: pixelSize) {
            mustKeepFaceHeights[id] = smallest
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
        mustKeepFaceHeights: mustKeepFaceHeights,
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

    // Per-photo cell AREA (fraction of the full canvas) in both variants -
    // solved once more at `nominalCanvas` (proportions are scale-invariant,
    // same reasoning `renderComparisonSheet`'s own doc comment already
    // relies on, so this doesn't need to match the render's own 900pt panel
    // canvas to be a faithful fraction).
    let canvasArea = Double(nominalCanvas.width) * Double(nominalCanvas.height)
    let (defaultCells, _) = solve(root: previousAssigned, canvasSize: nominalCanvas, border: border)
    let (faceAwareCells, _) = solve(root: decision.template, canvasSize: nominalCanvas, border: border)
    let defaultAreaByID = Dictionary(uniqueKeysWithValues: defaultCells.map { ($0.id, Double($0.rect.width) * Double($0.rect.height) / canvasArea) })
    let faceAwareAreaByID = Dictionary(uniqueKeysWithValues: faceAwareCells.map { ($0.id, Double($0.rect.width) * Double($0.rect.height) / canvasArea) })
    for id in order {
        perPhotoRows.append(PerPhotoRow(
            setName: setName,
            fileName: fileNameByID[id] ?? "?",
            faceCount: photosByID[id]?.survivingFaces.count ?? 0,
            smallestFaceHeightFraction: mustKeepFaceHeights[id],
            defaultCellAreaFraction: defaultAreaByID[id] ?? 0,
            faceAwareCellAreaFraction: faceAwareAreaByID[id] ?? 0
        ))
    }

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

// ---- per_photo.csv --------------------------------------------------------
// See `PerPhotoRow`'s own doc comment for why this exists alongside (not
// instead of) summary.csv: judging the group-photo-cell-size rule needs
// PER-PHOTO face counts and cell areas, which a per-SET total can't give.
var perPhotoCSV = "set,file,face_count,smallest_face_height_fraction,default_cell_area_fraction,face_aware_cell_area_fraction\n"
for row in perPhotoRows {
    perPhotoCSV += [
        row.setName,
        csvField(row.fileName),
        String(row.faceCount),
        row.smallestFaceHeightFraction.map { String(format: "%.4f", $0) } ?? "",
        String(format: "%.4f", row.defaultCellAreaFraction),
        String(format: "%.4f", row.faceAwareCellAreaFraction)
    ].joined(separator: ",") + "\n"
}
let perPhotoURL = URL(fileURLWithPath: outputDirPath).appendingPathComponent("per_photo.csv")
try? perPhotoCSV.write(to: perPhotoURL, atomically: true, encoding: .utf8)

print("LayoutLab: wrote \(summaryRows.count) sheet(s) + summary.csv + per_photo.csv to \(outputDirPath)")
