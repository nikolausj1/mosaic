# LayoutLab

A macOS command-line tuning harness for Magic Layout (B32), Phase 4 groundwork.

**The problem it solves:** the face-aware layout decision
(`Sources/Engine/MagicLayout.swift`) has only ever been judged against ~4
curated prototype photos. Judging it against a real camera roll today means
running the app and building a collage by hand, one at a time - far too slow
to tune scoring weights against. This tool takes a folder of photos, forms
them into sets, runs the REAL decision code (not a re-implementation), and
renders a contact sheet of the result as a PNG per set so a human can flip
through and judge quickly.

## How it works

`Sources/Engine/**` is platform-pure Swift (Foundation/CoreGraphics only, no
UIKit) and already compiles standalone - the same way `Tests/SmokeTest.swift`
does (see the Project Build Guide). This tool links those same Engine
sources directly, plus its own small set of files under `Sources/`, via one
`swiftc` invocation - no Xcode project, no simulator. Vision and CoreImage
are fully available on macOS, so it runs REAL face detection, not a stub.

Per photo, this mirrors two existing files exactly rather than
re-implementing them:

- **`Sources/App/Library/PhotoLibraryService.swift`**: the same 2000px-capped,
  orientation-corrected proxy (`kCGImageSourceThumbnailMaxPixelSize: 2000`,
  `kCGImageSourceCreateThumbnailWithTransform: true`) as
  `loadForEditing`, and the same two Vision requests
  (`VNDetectFaceRectanglesRequest` + `VNGenerateAttentionBasedSaliencyImageRequest`)
  with the same bottom-left -> top-left conversion as
  `visionInputs(cgImage:)`.
- **`Sources/App/Library/PickerView.swift`**'s `buildDocument`: the same call
  sequence - `mustKeepRegion` per photo, then `faceAwareAssignment` for the
  face-aware decision, and the same `defaultTemplateIndex` +
  `contentFitAssignment` pair `buildDocument`'s own DEBUG block computes for
  the "what would today's app have chosen" comparison.

Both variants are then solved (`solve(root:canvasSize:border:)`) and each
photo is auto-framed into its cell (`autoFrame`) exactly as the app does, so
the rendered crop is the crop the app would actually produce - not an
approximation.

## Usage

```bash
Tools/LayoutLab/run.sh <photo-folder> [setSize=4] [outputDir]
```

- `<photo-folder>`: a folder of JPEG/HEIC/PNG photos.
- `[setSize]`: 2-4, default 4.
- `[outputDir]`: default `$TMPDIR/LayoutLab-output` - deliberately OUTSIDE
  the repo. **This repo is public.** `run.sh` refuses to write inside the
  repo even if you pass a path there, since a rendered sheet embeds the
  actual test photos.

Example:

```bash
Tools/LayoutLab/run.sh ~/Pictures/CameraRollSample 4
```

Output: one `setNN.png` per set, plus one `summary.csv` covering every set,
both in `outputDir`.

### Grouping (v1)

Photos are sorted by filename (`localizedStandardCompare` - Finder-style,
numeric-aware) and chunked sequentially into groups of `setSize`. A trailing
remainder of fewer than 2 photos is dropped (the Engine's own
`templates(for:)` / `faceAwareAssignment` precondition is 2-4 photos) and
reported on stderr. This is a v1 placeholder - it does not group by time,
scene, or people; smarter grouping is future work, not this tool's job.

## Reading a sheet

Each `setNN.png` is one row: a title strip (set name + filenames), then two
panels side by side:

- **Left - "WITHOUT face-aware"**: the layout `defaultTemplateIndex` +
  `contentFitAssignment` would produce (today's aspect-only path, no face
  awareness at all).
- **Right - "FACE-AWARE"**: `faceAwareAssignment`'s real decision, with its
  template index and cost shown in the header.

Each cell shows the actual cropped photo (the same crop the app itself would
render, via `autoFrame`), with every surviving detected face (the Engine's
own threshold: confidence >= 0.5, height >= 8% of the photo's short edge)
outlined:

- **Cyan** - the face survives fully inside the crop.
- **Red, thicker** - the face is clipped (partially or fully outside the
  crop) - the single most important failure to spot at a glance.

## summary.csv

One row per set: set name, photo count, faces detected (raw Vision output)
and faces kept (post-threshold), the template index each variant chose, the
face-aware decision's cost, faces clipped in each variant, and whether the
two variants differ at all (`changed`).

## per_photo.csv

One row per PHOTO (not per set) - added for the group-photo-cell-size rule
(the "bigger cell for a group shot, smaller for a selfie" request): `faces_kept`
in `summary.csv` is a SET total, which can't tell a 6-person group photo
with a small cell apart from a 1-person selfie with a big one in the same
set. Columns: set, file, `face_count` (surviving faces in that photo),
`smallest_face_height_fraction` (blank when the photo has no surviving
face), and `default_cell_area_fraction` / `face_aware_cell_area_fraction`
(each cell's area as a fraction of the full canvas, in the
without-face-awareness and face-aware layouts respectively). Judge the rule
by sorting a set's rows by `face_count` descending and checking that
`face_aware_cell_area_fraction` is non-increasing down the list (more faces
-> at least as much area), not by eyeballing the sheet alone.

## File ownership

This tool owns only `Tools/LayoutLab/`. It never edits anything under
`Sources/` - it only reads and links against `Sources/Engine/**` at build
time.

## Test data

`Sources/Resources/Prototype/proto1.jpg` - `proto4.jpg` are gitignored
personal photos, useful for an end-to-end smoke test of this tool. **Never
copy them (or any rendered PNG containing them) anywhere that could be
committed** - the GitHub repo is public. Point `run.sh` at a copy of them (or
any other folder) OUTSIDE the repo, with an `outputDir` also outside the
repo (the default already is).
