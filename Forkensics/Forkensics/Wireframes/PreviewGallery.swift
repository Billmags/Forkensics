import SwiftUI

struct ForkensicsPreviewGallery: View {
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 24) {
                PreviewFrame(title: "Welcome") {
                    WelcomeWireframe(startSample: {}, signIn: {})
                }
                PreviewFrame(title: "Cases") {
                    ForkensicsMainShell()
                }
                PreviewFrame(title: "Active Case") {
                    ActiveCaseWireframe(makeGuess: {})
                }
                PreviewFrame(title: "Reveal") {
                    CaseRevealedWireframe(scoreBreakdown: {}, nextCase: {})
                }
            }
            .padding()
        }
        .background(Color.gray.opacity(0.15))
    }
}

private struct PreviewFrame<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.black)
            content
                .frame(width: 393, height: 852)
                .clipShape(RoundedRectangle(cornerRadius: 34))
                .overlay { RoundedRectangle(cornerRadius: 34).stroke(Color.black.opacity(0.15)) }
        }
    }
}

struct ForkensicsPreviewGallery_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ForkensicsPreviewGallery()
                .previewDisplayName("Wireframe Gallery")

            ForkensicsRootWireframe(initialPhase: .welcome)
                .previewDevice("iPhone SE (3rd generation)")
                .previewDisplayName("Welcome — compact")

            ForkensicsRootWireframe(initialPhase: .signedIn)
                .previewDevice("iPhone 16 Pro Max")
                .previewDisplayName("Cases — large")

            ActiveCaseWireframe(makeGuess: {})
                .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
                .previewDevice("iPhone 16 Pro")
                .previewDisplayName("Active Case — AX XXXL")
        }
    }
}
