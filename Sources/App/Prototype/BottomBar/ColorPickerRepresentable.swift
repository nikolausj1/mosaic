// Sources/App/Prototype/BottomBar/ColorPickerRepresentable.swift
// Thin UIViewControllerRepresentable wrapper around the system color picker,
// used by the Border tray's "+" swatch (Phase 4).
import SwiftUI
import UIKit

struct SystemColorPickerRepresentable: UIViewControllerRepresentable {
    var initialColor: UIColor
    var onPicked: (RGBA) -> Void
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.selectedColor = initialColor
        picker.supportsAlpha = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIColorPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        let onPicked: (RGBA) -> Void
        let onDismiss: () -> Void

        init(onPicked: @escaping (RGBA) -> Void, onDismiss: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onDismiss = onDismiss
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            onDismiss()
        }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            onPicked(RGBA(r: Double(r), g: Double(g), b: Double(b), a: 1.0))
        }
    }
}
