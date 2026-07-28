// Sources/App/Prototype/BottomBar/ColorPickerRepresentable.swift
// System color picker for the Border tray's "+" swatch, presented DIRECTLY
// from UIKit rather than a SwiftUI .sheet (Justin, 2026-07-26): the picker's
// built-in eyedropper dismisses its presenting sheet to sample the screen,
// and inside a SwiftUI sheet that teardown races the live sampler overlay -
// the picker (and its delegate) could deallocate while the loupe was still
// up, crashing on selection. Presenting from the top UIKit view controller
// keeps the picker alive for the sampler's whole lifetime; the strong
// `activeDelegate` reference below is what guarantees the delegate outlives
// it too (UIColorPickerViewController.delegate is weak).
import SwiftUI
import UIKit

@MainActor
enum SystemColorPicker {
    private static var activeDelegate: PickerDelegate?

    static func present(initialColor: UIColor, onPicked: @escaping (RGBA) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = (scene.keyWindow ?? scene.windows.first)?.rootViewController
        else { return }

        var top = root
        while let presented = top.presentedViewController { top = presented }

        let picker = UIColorPickerViewController()
        picker.selectedColor = initialColor
        picker.supportsAlpha = false

        let delegate = PickerDelegate(onPicked: onPicked)
        picker.delegate = delegate
        activeDelegate = delegate

        top.present(picker, animated: true)
    }

    private final class PickerDelegate: NSObject, UIColorPickerViewControllerDelegate {
        let onPicked: (RGBA) -> Void

        init(onPicked: @escaping (RGBA) -> Void) {
            self.onPicked = onPicked
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            SystemColorPicker.activeDelegate = nil
        }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            onPicked(RGBA(r: Double(r), g: Double(g), b: Double(b), a: 1.0))
        }
    }
}
