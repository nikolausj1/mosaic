// Sources/App/Export/SaveSheetView.swift
// PRD Screen C - the modal sheet presented after a successful Save: the
// ACTUAL exported UIImage (not a re-render of the canvas), "Saved to
// Photos", real pixel dimensions, Share (system share sheet) | Done.
import SwiftUI
import UIKit

struct SaveSheetView: View {
    let result: SaveResult
    var onDone: () -> Void
    var storeService: StoreService

    @State private var showShareSheet = false
    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Image(uiImage: result.image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                .padding(.horizontal, 24)

            VStack(spacing: 4) {
                Text("Saved to Photos")
                    .font(.headline)
                Text("\(Int(result.pixelSize.width)) x \(Int(result.pixelSize.height))")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }

            // B8: the only disclosure of the watermark in the whole app -
            // the live editor canvas never previews it (deliberate, PRD
            // "quiet UI"). Entitled users see nothing here at all.
            if !storeService.isUnlocked {
                watermarkNotice
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(Color.mosaicSurface)
                .foregroundStyle(Color.mosaicAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(Color.mosaicAccent)
                .foregroundStyle(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mosaicBackground.ignoresSafeArea())
        .sheet(isPresented: $showShareSheet) {
            ActivityView(activityItems: [shareFileURL() ?? result.jpegData])
        }
        .sheet(isPresented: $showPaywall) {
            PaywallSheet(storeService: storeService)
        }
    }

    private var watermarkNotice: some View {
        HStack(spacing: 6) {
            Text("Saves with a small Mosaic watermark")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
            Button {
                showPaywall = true
            } label: {
                Text("Remove")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.mosaicAccent)
            }
        }
    }

    /// Writes the JPEG to a temp file so the share sheet offers "Save
    /// Image"/AirDrop/Files with a real filename rather than raw Data.
    private func shareFileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mosaic-\(UUID().uuidString).jpg")
        do {
            try result.jpegData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
