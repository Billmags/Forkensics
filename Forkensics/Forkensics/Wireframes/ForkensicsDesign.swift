import SwiftUI

enum ForkensicsColor {
    static let background = Color(hex: 0x050505)
    static let surface = Color(hex: 0x111111)
    static let raised = Color(hex: 0x181818)
    static let line = Color.white.opacity(0.12)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let mutedText = Color.white.opacity(0.42)
    static let orange = Color(hex: 0xFF5A0A)
    static let orangeSoft = Color(hex: 0xFF7A32)
}

enum ForkensicsSpacing {
    static let xSmall: CGFloat = 6
    static let small: CGFloat = 10
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
    static let screen: CGFloat = 18
    static let cardRadius: CGFloat = 16
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension View {
    func forkensicsScreen() -> some View {
        self
            .foregroundStyle(ForkensicsColor.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ForkensicsColor.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    func forkensicsCard() -> some View {
        self
            .padding(ForkensicsSpacing.medium)
            .background(ForkensicsColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius, style: .continuous)
                    .stroke(ForkensicsColor.line, lineWidth: 1)
            }
    }
}
