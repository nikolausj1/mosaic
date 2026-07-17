// Sources/App/Export/SaveSheetView.swift
// PRD Screen C - the modal sheet presented after a successful Save: the
// ACTUAL exported UIImage (not a re-render of the canvas), "Saved to
// Photos", real pixel dimensions, Share (system share sheet) | Done.
import SwiftUI
import UIKit

struct SaveSheetView: View {
    let result: SaveResult
    var onDone: () -> Void

    @State private var showShareSheet = false

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
