// Tools/WeightSweep/Sources/main.swift
// WeightSweep - the B32 "which framingCost weights should we ship" decision
// aid. Sibling to `Tools/LayoutLab`, not a replacement: LayoutLab answers
// "does face-aware beat today's aspect-only layout"; this tool answers "of
// several CANDIDATE weight tunings for framingCost, which one should we
// ship" by running the REAL decision code (the same
// `Sources/Engine/MagicLayout.swift` functions LayoutLab calls) once per
// (photo set x weight config) and rendering all configs for one set side by
// side so a human can flip through and judge.
//
// Reuses `Tools/LayoutLab/Sources/{PhotoLoading,VisionDetect,Render}.swift`
// UNCHANGED (this tool's own `run.sh` compiles them straight from
// `Tools/LayoutLab/Sources/`, right alongside `Sources/Engine/*.swift` and
// this file) - Vision detection and rendering do not depend on
// `framingCost`'s weights at all, so there is no reason to duplicate that
// code, and every coordinate-space/orientation trap those files already
// carry comments about applies here unchanged.
//
// THE PROBLEM THIS EXISTS FOR (see the B32 group-photo-cell-size build-log
// entries and `MagicLayout.swift`'s `dividerSearchGrid`/`FramingCostWeight`
// comments for the full trail): the photo with the most people should get
// the most cell area, and today it often does not. The legibility term that
// is supposed to fix this is CAPPED at a small per-photo maximum
// (`legibility weight * minLegibleFaceHeightFraction`, 2.4 today) while the
// clip-avoidance and aspect-mismatch terms are UNCAPPED - so a more thorough
// search chases the uncapped terms, which can move area AWAY from the group
// photo. Raising the legibility WEIGHT to 120 fixes one real case and
// creates four new clipped faces elsewhere (measured, not theoretical - see
// the same build-log entry). Nobody can pick the right weights by reasoning
// about this in the abstract; the owner has to SEE the output across a real
// photo corpus. That is what this tool produces - it does NOT pick a winner.
//
// Usage:
//   weightsweep <photo-folder> <output-dir> [setSize=4]
// Same argument contract as LayoutLab (see that tool's own `run.sh`/README):
// setSize 2-4, output-dir must resolve OUTSIDE the repo (this repo is
// PUBLIC and every rendered sheet embeds real personal photos) - enforced by
// this tool's own `run.sh`, same guard LayoutLab's `run.sh` already has.
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
    Usage: weightsweep <photo-folder> <output-dir> [setSize=4]

    <photo-folder>  Folder of JPEG/HEIC/PNG photos.
    <output-dir>    Where sheet PNGs + CSVs are written. Run via run.sh,
                    which supplies a safe (never-in-repo) default.
    [setSize]       2-4, default 4. See LayoutLab's README for the grouping rule.
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
    fail("WeightSweep: no photo sets found in \(photoFolder) (need at least 2 photos of a supported type: \(supportedPhotoExtensions.sorted().joined(separator: ", ")))")
}
print("WeightSweep: \(sets.count) set(s), set size \(setSize), \(droppedCount) trailing photo(s) dropped (< 2 remaining).")

// Same fresh-collage border and nominal decision canvas LayoutLab uses - see
// that tool's own main.swift comment for why zero border / 1000x1000 square
// matches the app's real starting point and is scale-invariant besides.
let border = BorderStyle(inner: 0, outer: 0, linked: true, cornerRadius: 0, color: .white)
let nominalCanvas = CGSize(width: 1000, height: 1000)

// ---- The candidate weight configurations ----------------------------------
//
// Every config starts from `FramingWeights.current` (Part 1's injected
// default - today's shipped `FramingCostWeight` values, byte-identical) and
// changes exactly the ONE thing its name says, so a difference in the
// rendered sheets or the summary table is attributable to that one change
// alone. `note` is printed in the summary and is the ONE place a human
// reads to know what a config actually did.
struct WeightConfig {
    let name: String
    let weights: FramingWeights
    let note: String
}

private func modified(_ base: FramingWeights = .current, _ change: (inout FramingWeights) -> Void) -> FramingWeights {
    var w = base
    change(&w)
    return w
}

let configs: [WeightConfig] = [
    WeightConfig(
        name: "current",
        weights: .current,
        note: "Today's shipped values, unchanged - the control every other row is measured against."
    ),
    WeightConfig(
        name: "legibility-60",
        weights: modified { $0.legibility = 60 },
        note: "Legibility weight 20 -> 60 (per-photo cap 2.4 -> 7.2). The obvious lever."
    ),
    WeightConfig(
        name: "legibility-120",
        weights: modified { $0.legibility = 120 },
        note: "Legibility weight 20 -> 120 (cap 2.4 -> 14.4). Known from the B32 investigation to fix one real case and introduce 4 new clipped faces elsewhere - included so that cost is visible here too, not just asserted."
    ),
    WeightConfig(
        name: "aspect-0.25",
        weights: modified { $0.aspect = 0.25 },
        note: "Aspect-mismatch weight 1.0 -> 0.25 (the UNCAPPED term de-weighted, not legibility raised) - the diagnosis names this term, alongside clip-avoidance, as what an uncapped legibility term loses to."
    ),
    WeightConfig(
        name: "cap-0.18",
        weights: modified { $0.minLegibleFaceHeightFraction = 0.18 },
        note: "Legibility CAP raised (minLegibleFaceHeightFraction 0.12 -> 0.18, max per-photo contribution 2.4 -> 3.6); weight left at 20. Moderate move."
    ),
    WeightConfig(
        name: "cap-0.30",
        weights: modified { $0.minLegibleFaceHeightFraction = 0.30 },
        note: "Same lever as cap-0.18, pushed further (0.12 -> 0.30, cap 2.4 -> 6.0; weight still 20) - shows the trend of raising the CAP rather than the weight."
    ),
    WeightConfig(
        name: "combo-legibility60-aspect0.25",
        weights: modified { $0.legibility = 60; $0.aspect = 0.25 },
        note: "Exploratory: both single-lever changes above (legibility weight up, aspect weight down) applied together, to see whether combining them reaches an agreement/clip trade the single levers do not."
    )
]

// ---- Per-set, per-config accumulation --------------------------------------

struct SetPhotoInfo {
    let setName: String
    let order: [PhotoID]
    let photosByID: [PhotoID: PhotoData]
    let pixelSizes: [PhotoID: CGSize]
    let mustKeepRegions: [PhotoID: CGRect]
    let mustKeepFaceHeights: [PhotoID: Double]
    let fileNameByID: [PhotoID: String]
}

struct ConfigAccumulator {
    var clippedFacesTotal = 0
    var agreementCount = 0
    var scorableSetCount = 0
    var totalDecisionTimeMs = 0.0
    var setCount = 0
}

struct DetailRow {
    var setName: String
    var configName: String
    var templateIndex: Int
    var cost: Double
    var clippedFaces: Int
    var decisionTimeMs: Double
    var agreement: String // "yes" / "no" / "n/a" (all photos tied on face count)
}

struct PerPhotoRow {
    var setName: String
    var configName: String
    var fileName: String
    var faceCount: Int
    var cellAreaFraction: Double
}

var accumulators: [String: ConfigAccumulator] = Dictionary(uniqueKeysWithValues: configs.map { ($0.name, ConfigAccumulator()) })
var detailRows: [DetailRow] = []
var perPhotoRows: [PerPhotoRow] = []
var baselineClippedTotal = 0 // WITHOUT-face-aware reference panel, weight-independent - for cross-checking against LayoutLab's own summary.csv.

for (setIndex, files) in sets.enumerated() {
    let setName = "set\(String(format: "%02d", setIndex + 1))"
    print("WeightSweep: \(setName) - \(files.map(\.lastPathComponent).joined(separator: ", "))")

    var order: [PhotoID] = []
    var photosByID: [PhotoID: PhotoData] = [:]
    var pixelSizes: [PhotoID: CGSize] = [:]
    var mustKeepRegions: [PhotoID: CGRect] = [:]
    var mustKeepFaceHeights: [PhotoID: Double] = [:]
    var fileNameByID: [PhotoID: String] = [:]
    var loadFailures: [String] = []

    for url in files {
        guard let (cgImage, pixelSize) = loadPhotoProxy(url: url) else {
            loadFailures.append(url.lastPathComponent)
            continue
        }
        let id = PhotoID()
        let vision = runVisionInputs(cgImage: cgImage)
        let kept = thresholdedFaces(faces: vision.faces.map(\.0), faceConfidences: vision.faces.map(\.1), photoPixelSize: pixelSize)

        order.append(id)
        pixelSizes[id] = pixelSize
        fileNameByID[id] = url.lastPathComponent
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
        FileHandle.standardError.write("WeightSweep: \(setName) - failed to load \(loadFailures.joined(separator: ", "))\n".data(using: .utf8)!)
    }
    guard order.count >= 2 else {
        FileHandle.standardError.write("WeightSweep: \(setName) - fewer than 2 photos loaded, skipping\n".data(using: .utf8)!)
        continue
    }

    // ---- Reference panel: today's WITHOUT-face-aware layout, weight-
    // independent (never calls framingCost at all) - included purely as a
    // fixed anchor so a human flipping through can see how far EVERY
    // face-aware config already is from today's aspect-only baseline, and so
    // this tool's own clipped-face total can be cross-checked against
    // LayoutLab's `summary.csv` (22 default / 2 face-aware at setSize 4, 29 /
    // 2 at setSize 3, over this same corpus). ----
    let orientations = order.map { pixelSizes[$0] ?? CGSize(width: 1, height: 1) }
    let candidateTemplates = templates(for: order)
    let previousIndex = min(defaultTemplateIndex(orientations: orientations), candidateTemplates.count - 1)
    let previousAssigned = contentFitAssignment(
        photoSizes: pixelSizes,
        template: candidateTemplates[previousIndex],
        canvasSize: nominalCanvas,
        border: border
    )

    var variants: [RenderVariant] = [
        RenderVariant(label: "today (no face-aware)", template: previousAssigned, templateIndex: previousIndex, extra: "")
    ]

    // ---- One decision per weight config, same photos, same canvas. ----
    var configResults: [(config: WeightConfig, decision: FaceAwareAssignment, timeMs: Double)] = []
    for config in configs {
        let start = Date()
        let decision = faceAwareAssignment(
            photos: order,
            photoSizes: pixelSizes,
            mustKeepRegions: mustKeepRegions,
            mustKeepFaceHeights: mustKeepFaceHeights,
            canvasSize: nominalCanvas,
            border: border,
            weights: config.weights
        )
        let timeMs = Date().timeIntervalSince(start) * 1000
        configResults.append((config, decision, timeMs))
        variants.append(RenderVariant(
            label: config.name,
            template: decision.template,
            templateIndex: decision.templateIndex,
            extra: String(format: " · cost %.3f", decision.cost)
        ))
    }

    let outputURL = URL(fileURLWithPath: outputDirPath).appendingPathComponent("\(setName)_sweep.png")
    let panelResults = renderComparisonSheet(
        setLabel: setName,
        fileNames: files.map(\.lastPathComponent),
        photosByID: photosByID,
        variants: variants,
        border: border,
        outputURL: outputURL
    )
    baselineClippedTotal += panelResults.first?.clippedFaceCount ?? 0

    let canvasArea = Double(nominalCanvas.width) * Double(nominalCanvas.height)

    for (offset, result) in configResults.enumerated() {
        let panelIndex = offset + 1 // panel 0 is the "today" reference
        let clipped = panelIndex < panelResults.count ? panelResults[panelIndex].clippedFaceCount : 0

        var acc = accumulators[result.config.name] ?? ConfigAccumulator()
        acc.clippedFacesTotal += clipped
        acc.totalDecisionTimeMs += result.timeMs
        acc.setCount += 1

        // ---- Area-vs-faces agreement for THIS config's decision. ----
        // "Does the photo with the most detected faces get the largest
        // cell?" - detected here means SURVIVING faces (post-threshold, the
        // same `thresholdedFaces` count the legibility term itself scores
        // against), not raw Vision output, since raw output can include
        // faces the Engine itself already discards as noise. A set where
        // every photo ties on face count (including an all-zero set with no
        // faces anywhere) has no "most-faced photo" to check, so it is
        // excluded from the denominator rather than counted as a free win -
        // reported separately as "n/a" in the detail CSV. A tie for the max
        // AREA is resolved with a small relative tolerance (0.5%) so
        // floating-point noise in the divider search never manufactures a
        // false disagreement.
        let (cells, _) = solve(root: result.decision.template, canvasSize: nominalCanvas, border: border)
        let areaByID = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, Double($0.rect.width) * Double($0.rect.height) / canvasArea) })

        for id in order {
            perPhotoRows.append(PerPhotoRow(
                setName: setName,
                configName: result.config.name,
                fileName: fileNameByID[id] ?? "?",
                faceCount: photosByID[id]?.survivingFaces.count ?? 0,
                cellAreaFraction: areaByID[id] ?? 0
            ))
        }

        let faceCounts = order.map { photosByID[$0]?.survivingFaces.count ?? 0 }
        let maxFaceCount = faceCounts.max() ?? 0
        let topFacePhotos = order.filter { (photosByID[$0]?.survivingFaces.count ?? 0) == maxFaceCount }

        var agreementLabel = "n/a"
        if topFacePhotos.count < order.count {
            // A genuine "most-faced" subset exists (not every photo tied).
            let maxArea = order.map { areaByID[$0] ?? 0 }.max() ?? 0
            let areaTieTolerance = maxArea * 0.005
            let agrees = topFacePhotos.contains { (areaByID[$0] ?? 0) >= maxArea - areaTieTolerance }
            agreementLabel = agrees ? "yes" : "no"
            acc.scorableSetCount += 1
            if agrees { acc.agreementCount += 1 }
        }

        accumulators[result.config.name] = acc

        detailRows.append(DetailRow(
            setName: setName,
            configName: result.config.name,
            templateIndex: result.decision.templateIndex,
            cost: result.decision.cost,
            clippedFaces: clipped,
            decisionTimeMs: result.timeMs,
            agreement: agreementLabel
        ))
    }
}

// ---- sweep_summary.csv -----------------------------------------------------
// One row per weight config - the table Justin actually reads: clipped faces
// (must not regress vs. `current`), area-vs-faces agreement as "k/n" (the
// number that matters most - see this tool's own header comment), and mean
// decision time. Does NOT pick a winner - see this file's own header comment
// and the tool's report.
func csvField(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return s
}

var summaryCSV = "config,note,clipped_faces_total,area_vs_faces_agreement,scorable_sets,total_sets,mean_decision_time_ms,total_decision_time_ms\n"
print("\n==== WeightSweep summary (\(sets.count) set(s), setSize \(setSize)) ====")
print("config".padding(toLength: 32, withPad: " ", startingAt: 0) + " " + "clipped".padding(toLength: 10, withPad: " ", startingAt: 0) + " " + "agreement".padding(toLength: 14, withPad: " ", startingAt: 0) + " " + "mean ms")
for config in configs {
    let acc = accumulators[config.name] ?? ConfigAccumulator()
    let agreementFraction = "\(acc.agreementCount)/\(acc.scorableSetCount)"
    let meanMs = acc.setCount > 0 ? acc.totalDecisionTimeMs / Double(acc.setCount) : 0
    summaryCSV += [
        config.name,
        csvField(config.note),
        String(acc.clippedFacesTotal),
        agreementFraction,
        String(acc.scorableSetCount),
        String(acc.setCount),
        String(format: "%.4f", meanMs),
        String(format: "%.4f", acc.totalDecisionTimeMs)
    ].joined(separator: ",") + "\n"
    print("\(config.name.padding(toLength: 32, withPad: " ", startingAt: 0)) \(String(acc.clippedFacesTotal).padding(toLength: 10, withPad: " ", startingAt: 0)) \(agreementFraction.padding(toLength: 14, withPad: " ", startingAt: 0)) \(String(format: "%.3f", meanMs))")
}
print("(reference: today's WITHOUT-face-aware layout clipped \(baselineClippedTotal) faces total across this run, weight-independent - cross-check against LayoutLab's own summary.csv)")

let summaryURL = URL(fileURLWithPath: outputDirPath).appendingPathComponent("sweep_summary.csv")
try? summaryCSV.write(to: summaryURL, atomically: true, encoding: .utf8)

// ---- sweep_detail.csv -------------------------------------------------------
// One row per (set, config) - lets a human audit any single summary number
// back to the exact sets it came from, without re-running anything.
var detailCSV = "set,config,template_index,cost,clipped_faces,decision_time_ms,area_vs_faces_agreement\n"
for row in detailRows {
    detailCSV += [
        row.setName,
        row.configName,
        String(row.templateIndex),
        String(format: "%.4f", row.cost),
        String(row.clippedFaces),
        String(format: "%.4f", row.decisionTimeMs),
        row.agreement
    ].joined(separator: ",") + "\n"
}
let detailURL = URL(fileURLWithPath: outputDirPath).appendingPathComponent("sweep_detail.csv")
try? detailCSV.write(to: detailURL, atomically: true, encoding: .utf8)

// ---- sweep_per_photo.csv ----------------------------------------------------
// One row per (set, config, photo) - the numbers behind the
// area_vs_faces_agreement column: sort a (set, config) group by face_count
// descending and check cell_area_fraction is non-increasing, exactly the way
// LayoutLab's own per_photo.csv's doc comment recommends judging the
// group-photo-cell-size rule, but with a config dimension added.
var perPhotoCSV = "set,config,file,face_count,cell_area_fraction\n"
for row in perPhotoRows {
    perPhotoCSV += [
        row.setName,
        row.configName,
        csvField(row.fileName),
        String(row.faceCount),
        String(format: "%.4f", row.cellAreaFraction)
    ].joined(separator: ",") + "\n"
}
let perPhotoURL = URL(fileURLWithPath: outputDirPath).appendingPathComponent("sweep_per_photo.csv")
try? perPhotoCSV.write(to: perPhotoURL, atomically: true, encoding: .utf8)

print("\nWeightSweep: wrote \(sets.count) sheet(s) (one per set, \(configs.count + 1) panels each) + sweep_summary.csv + sweep_detail.csv + sweep_per_photo.csv to \(outputDirPath)")
