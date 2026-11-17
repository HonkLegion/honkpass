import SwiftUI

/// Two opaque doors reveal a newly unlocked window. This view receives no vault data.
/// Locking hides the animation immediately; the caller must remove its unlocked content.
public struct VaultOpeningCover: View {
    private let isUnlocked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false

    public init(isUnlocked: Bool) {
        self.isUnlocked = isUnlocked
    }

    public var body: some View {
        GeometryReader { area in
            let half = area.size.width / 2
            HStack(spacing: 0) {
                Rectangle().fill(.theme(.bgTertiary))
                    .frame(width: half)
                    .offset(x: isOpen ? -half : 0)
                Rectangle().fill(.theme(.bgTertiary))
                    .frame(width: half)
                    .offset(x: isOpen ? half : 0)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: isOpen)
        }
        .clipped()
        .opacity(isUnlocked ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction { transaction in
            if !isUnlocked { transaction.disablesAnimations = true }
        }
        .task(id: isUnlocked) {
            if isUnlocked {
                // Let the closed cover enter the view hierarchy before its movement starts.
                await Task.yield()
                guard !Task.isCancelled else { return }
                isOpen = true
            } else {
                isOpen = false
            }
        }
    }
}
