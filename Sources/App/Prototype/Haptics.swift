// Sources/App/Prototype/Haptics.swift
// Tiny wrapper around UIKit's feedback generators, prepared ahead of time so
// the first tick/thump/floorBump of a gesture doesn't eat the warm-up latency.
import UIKit

final class Haptics {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)

    init() {
        light.prepare()
        medium.prepare()
        rigid.prepare()
    }

    /// Divider/bracket snap-to-candidate feedback.
    func tick() {
        light.impactOccurred()
        light.prepare()
    }

    /// Swap-mode entry / swap commit feedback.
    func thump() {
        medium.impactOccurred()
        medium.prepare()
    }

    /// Divider/corner drag hits the 0.10 fraction floor.
    func floorBump() {
        rigid.impactOccurred()
        rigid.prepare()
    }
}
