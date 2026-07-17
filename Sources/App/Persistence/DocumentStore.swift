// Sources/App/Persistence/DocumentStore.swift
// Phase 6 persistence contract (PRD): two files in Application Support/Mosaic/
// - current.json (in-progress document, autosaved continuously) and last.json
// (the archived just-saved document). Both are a tiny `{schemaVersion, document}`
// envelope, written atomically. Reads tolerate absence, and never crash on bad
// JSON: an undecodable file is renamed aside (`<name>.corrupt`) and treated as
// absent. App-layer only - never imported by Sources/Engine.
import Foundation
import UIKit

enum DocumentStore {

    private static let schemaVersion = 1

    private struct Envelope: Codable {
        var schemaVersion: Int
        var document: Document
    }

    // MARK: - Directories

    private static var mosaicDirectory: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mosaic", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var proxiesDirectory: URL {
        let url = mosaicDirectory.appendingPathComponent("proxies", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var currentURL: URL { mosaicDirectory.appendingPathComponent("current.json") }
    static var lastURL: URL { mosaicDirectory.appendingPathComponent("last.json") }

    // MARK: - Generic load/save (shared by current.json and last.json)

    /// Tolerant of absence (returns nil) and of corruption (renames the bad
    /// file aside as `<name>.corrupt` and returns nil) - never throws/crashes.
    private static func load(from url: URL) -> Document? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return envelope.document
        } catch {
            let corruptURL = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: corruptURL)
            try? FileManager.default.moveItem(at: url, to: corruptURL)
            return nil
        }
    }

    /// Atomic write (`Data.WritingOptions.atomic` - write-to-temp + rename
    /// under the hood). Best-effort: a write failure is swallowed rather than
    /// crashing the app (autosave should never take the editor down).
    private static func save(_ document: Document, to url: URL) {
        let envelope = Envelope(schemaVersion: schemaVersion, document: document)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - current.json

    static func loadCurrent() -> Document? { load(from: currentURL) }

    static func saveCurrent(_ document: Document) { save(document, to: currentURL) }

    static func deleteCurrent() { try? FileManager.default.removeItem(at: currentURL) }

    // MARK: - last.json

    static func loadLast() -> Document? { load(from: lastURL) }

    static var hasLastCollage: Bool { FileManager.default.fileExists(atPath: lastURL.path) }

    /// Save event (PRD): current.json -> last.json; current.json deleted.
    static func archiveCurrentAsLast() {
        guard let doc = loadCurrent() else {
            deleteCurrent() // nothing readable to archive - still honor "current deleted"
            return
        }
        save(doc, to: lastURL)
        deleteCurrent()
    }

    static func deleteLast() { try? FileManager.default.removeItem(at: lastURL) }

    /// "Edit last collage" (PRD): last.json -> current.json. Returns the
    /// promoted document (nil if there was no last.json to promote).
    @discardableResult
    static func promoteLastToCurrent() -> Document? {
        guard let doc = loadLast() else { return nil }
        save(doc, to: currentURL)
        deleteLast()
        return doc
    }

    // MARK: - Proxy sidecars (PHPicker-fallback photos, assetLocalIdentifier == "")

    /// Those photos have no PHAsset to re-fetch on restore, so their proxy
    /// UIImage is written to disk once (skipped if already present) whenever
    /// autosave sees them in the document.
    static func proxyURL(for photoID: PhotoID) -> URL {
        proxiesDirectory.appendingPathComponent("\(photoID.uuidString).jpg")
    }

    static func loadProxyImage(for photoID: PhotoID) -> UIImage? {
        UIImage(contentsOfFile: proxyURL(for: photoID).path)
    }

    static func saveProxyIfNeeded(photoID: PhotoID, image: UIImage) {
        let url = proxyURL(for: photoID)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes any proxy file not referenced (by an empty-`assetLocalIdentifier`
    /// photo) in any of `referencedDocuments` - called by autosave with
    /// [current, last] so a proxy stays around as long as either file needs it.
    static func garbageCollectProxies(referencedDocuments: [Document]) {
        var referencedIDs = Set<PhotoID>()
        for doc in referencedDocuments {
            for (id, photo) in doc.photos where photo.assetLocalIdentifier.isEmpty {
                referencedIDs.insert(id)
            }
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: proxiesDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard let id = PhotoID(uuidString: name), !referencedIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Debug: clean-slate reset (`-resetPersistence`)

    static func resetAll() {
        deleteCurrent()
        deleteLast()
        if let files = try? FileManager.default.contentsOfDirectory(at: proxiesDirectory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }
}
