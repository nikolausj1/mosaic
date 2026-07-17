# Mosaic

A collage tool for 2-4 photos where every proportion is set by dragging the thing itself. iPhone only, portrait only, iOS 18+, SwiftUI. No accounts, no backend, nothing leaves the device.

- **Spec:** [PRD.md](PRD.md)
- **Deferred decisions and their revisit triggers:** [Backlog.md](Backlog.md)

## Building

`project.yml` is the source of truth; the `.xcodeproj` is generated and gitignored.

```bash
xcodegen generate
xattr -cr Sources   # required before every build when the working copy lives in Dropbox
xcodebuild -project Mosaic.xcodeproj -scheme Mosaic build
```
