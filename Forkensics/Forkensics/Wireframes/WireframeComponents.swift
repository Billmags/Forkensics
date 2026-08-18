import SwiftUI
import UIKit

struct ForkensicsBrandView: View {
    var compact = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 9) {
                    brandImage
                        .frame(width: 34, height: 34)
                    Text("FORKENSICS")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(2.2)
                }
            } else {
            VStack(alignment: .leading, spacing: 1) {
                    brandImage
                        .frame(width: 148, height: 148)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                    Text("FORKENSICS")
                        .font(.system(size: 25, weight: .semibold))
                        .tracking(4)
                        .frame(maxWidth: .infinity)
                    Text("Crack the dish. Nail the place.")
                        .font(.caption)
                        .foregroundStyle(ForkensicsColor.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Forkensics. Crack the dish. Nail the place.")
    }

    private var brandImage: some View {
        Image("ForkensicsLogoNoText")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

struct ForkensicsHeader: View {
    @Environment(\.dismiss) private var dismiss

    var title: String? = nil
    var showsAlert = true
    var showsBackButton = false
    var backAction: (() -> Void)? = nil
    var alertAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if showsBackButton {
                Button {
                    if let backAction {
                        backAction()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(ForkensicsColor.primaryText)
                        .frame(width: 42, height: 42)
                        .background(ForkensicsColor.surface)
                        .clipShape(Circle())
                        .overlay {
                            Circle().stroke(ForkensicsColor.line, lineWidth: 1)
                        }
                }
                .buttonStyle(ForkensicsPressButtonStyle())
                .accessibilityLabel("Back")
            }
            if let title {
                Text(title.uppercased())
                    .font(.headline.weight(.bold))
                    .tracking(1)
            } else {
                ForkensicsBrandView(compact: true)
            }
            Spacer()
            if showsAlert {
                if let alertAction {
                    Button(action: alertAction) {
                        alertIcon
                    }
                    .buttonStyle(ForkensicsPressButtonStyle())
                    .accessibilityLabel("Alerts")
                } else {
                    alertIcon
                        .accessibilityLabel("Alerts")
                }
            }
        }
    }

    private var alertIcon: some View {
        Image(systemName: "bell")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(ForkensicsColor.primaryText)
            .frame(width: 42, height: 42)
            .background(ForkensicsColor.surface)
            .clipShape(Circle())
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(ForkensicsColor.orange)
                    .frame(width: 8, height: 8)
                    .offset(x: -4, y: 4)
            }
    }
}

struct ForkensicsPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}

struct ForkensicsPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled = true
    var providesLightHaptic = false
    let action: () -> Void

    var body: some View {
        Button {
            if providesLightHaptic {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title.uppercased())
                    .font(.subheadline.weight(.heavy))
                    .tracking(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .foregroundStyle(enabled ? Color.black : ForkensicsColor.mutedText)
            .background(enabled ? ForkensicsColor.orange : ForkensicsColor.raised)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ForkensicsPressButtonStyle())
        .disabled(!enabled)
    }
}

struct ForkensicsSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.subheadline.weight(.bold))
                .tracking(0.6)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .foregroundStyle(ForkensicsColor.primaryText)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(ForkensicsColor.line, lineWidth: 1)
                }
        }
        .buttonStyle(ForkensicsPressButtonStyle())
    }
}

struct ForkensicsSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(ForkensicsColor.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FoodPhotoPlaceholder: View {
    var height: CGFloat = 210
    var label = "Food photo"
    var imageName: String? = nil

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let imageName {
                    Image(imageName)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image("BurgerAndFries")
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: geometry.size.width, height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ForkensicsSpacing.cardRadius, style: .continuous)
                    .stroke(ForkensicsColor.line, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityLabel(label)
    }
}

struct ForkensicsRevealCelebration: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let points: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burstProgress: CGFloat = 0
    @State private var badgeScale: CGFloat = 0.72
    @State private var glowVisible = false
    @State private var displayedPoints = 0
    @State private var hasCelebrated = false

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    ForkensicsColor.orange.opacity(glowVisible ? 0.30 : 0.10),
                    ForkensicsColor.orange.opacity(0)
                ],
                center: .center,
                startRadius: 4,
                endRadius: 190
            )

            celebrationParticles

            VStack(spacing: 6) {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.black))
                    .tracking(1.8)
                    .foregroundStyle(ForkensicsColor.orangeSoft)

                ZStack {
                    Circle()
                        .fill(ForkensicsColor.orange.opacity(0.16))
                    Circle()
                        .stroke(ForkensicsColor.orange, lineWidth: 2)
                    Image(systemName: "party.popper.fill")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(ForkensicsColor.orange)
                }
                .frame(width: 52, height: 52)
                .scaleEffect(badgeScale)

                Text(title)
                    .font(.system(size: 30, weight: .black))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.78)

                Text(subtitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(ForkensicsColor.secondaryText)
                    .multilineTextAlignment(.center)

                HStack(spacing: 7) {
                    Image(systemName: "star.fill")
                    Text("+\(displayedPoints) POINTS")
                        .contentTransition(.numericText())
                }
                .font(.caption.weight(.black))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(ForkensicsColor.orange)
                .clipShape(Capsule())
                .scaleEffect(badgeScale)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 198)
        .background(
            LinearGradient(
                colors: [ForkensicsColor.raised, ForkensicsColor.surface],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(ForkensicsColor.orange.opacity(0.42), lineWidth: 1)
        }
        .task {
            await celebrate()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(subtitle). Plus \(points) points.")
    }

    private var celebrationParticles: some View {
        GeometryReader { geometry in
            ForEach(0..<18, id: \.self) { index in
                let angle = Double(index) * (2 * Double.pi / 18)
                let distance = min(geometry.size.width, geometry.size.height)
                    * (0.32 + CGFloat(index % 3) * 0.055)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index.isMultiple(of: 3) ? Color.white : ForkensicsColor.orange)
                    .frame(
                        width: index.isMultiple(of: 2) ? 5 : 9,
                        height: index.isMultiple(of: 2) ? 12 : 5
                    )
                    .rotationEffect(.degrees(Double(index * 31) + Double(burstProgress) * 120))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .offset(
                        x: CGFloat(cos(angle)) * distance * burstProgress,
                        y: CGFloat(sin(angle)) * distance * burstProgress
                    )
                    .opacity(reduceMotion ? 0 : 1 - Double(burstProgress))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @MainActor
    private func celebrate() async {
        guard !hasCelebrated else { return }
        hasCelebrated = true

        if reduceMotion {
            badgeScale = 1
            glowVisible = true
            displayedPoints = points
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.48, dampingFraction: 0.58)) {
            badgeScale = 1
            glowVisible = true
        }
        withAnimation(.easeOut(duration: 1.05)) {
            burstProgress = 1
        }

        try? await Task.sleep(for: .milliseconds(260))
        let increment = max(1, points / 22)
        while displayedPoints < points {
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.12)) {
                displayedPoints = min(points, displayedPoints + increment)
            }
            try? await Task.sleep(for: .milliseconds(24))
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

struct DetectiveAvatar: View {
    let detective: WireframeDetective
    var size: CGFloat = 46
    var showsName = true

    var body: some View {
        VStack(spacing: 5) {
            Text(detective.initials)
                .font(.caption.weight(.bold))
                .frame(width: size, height: size)
                .background(ForkensicsColor.raised)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(detective.isLocked ? ForkensicsColor.orange : ForkensicsColor.line, lineWidth: 2)
                }
            if showsName {
                Text(detective.name)
                    .font(.caption2)
                    .foregroundStyle(ForkensicsColor.secondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(detective.name), \(detective.isLocked ? "locked in" : "investigating")")
    }
}

struct DetectiveTableSeating: View {
    let tableName: String
    let detectives: [WireframeDetective]
    var statusText: String? = nil

    private enum TableShape {
        case circle
        case oval
        case longRectangle
    }

    private struct SeatingLayout {
        let shape: TableShape
        let center: CGPoint
        let tabletopSize: CGSize
        let seatPathSize: CGSize
        let cornerRadius: CGFloat
        let avatarSize: CGFloat
        let showsNames: Bool
    }

    private var seatedDetectives: [WireframeDetective] {
        Array(detectives.prefix(20))
    }

    private var lockedCount: Int {
        seatedDetectives.filter(\.isLocked).count
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = seatingLayout(for: seatedDetectives.count, availableWidth: geometry.size.width)
            let positions = seatPositions(for: layout, count: seatedDetectives.count)

            ZStack {
                tabletop(for: layout)
                    .position(layout.center)

                VStack(spacing: 4) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ForkensicsColor.orange)
                    Text(tableName.uppercased())
                        .font(.caption2.weight(.heavy))
                        .tracking(0.8)
                    Text(statusText ?? "\(lockedCount) OF \(seatedDetectives.count) LOCKED IN")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ForkensicsColor.secondaryText)
                }
                .position(layout.center)

                ForEach(Array(seatedDetectives.enumerated()), id: \.element.id) { index, detective in
                    DetectiveAvatar(
                        detective: detective,
                        size: layout.avatarSize,
                        showsName: layout.showsNames
                    )
                    .frame(width: layout.showsNames ? 66 : layout.avatarSize)
                    .position(positions[index])
                    .offset(y: layout.showsNames ? 9 : 0)
                }
            }
        }
        .frame(height: componentHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(tableName), \(statusText ?? "\(lockedCount) of \(seatedDetectives.count) detectives locked in")"
        )
    }

    private var componentHeight: CGFloat {
        switch seatedDetectives.count {
        case ...6: return 268
        case ...12: return 282
        default: return 300
        }
    }

    private func seatingLayout(for count: Int, availableWidth: CGFloat) -> SeatingLayout {
        if count <= 6 {
            let pathDiameter = min(224, availableWidth - 60)
            return SeatingLayout(
                shape: .circle,
                center: CGPoint(x: availableWidth / 2, y: 140),
                tabletopSize: CGSize(width: 154, height: 154),
                seatPathSize: CGSize(width: pathDiameter, height: pathDiameter),
                cornerRadius: 0,
                avatarSize: 44,
                showsNames: true
            )
        }

        if count <= 12 {
            let pathWidth = min(270, availableWidth - 44)
            return SeatingLayout(
                shape: .oval,
                center: CGPoint(x: availableWidth / 2, y: 141),
                tabletopSize: CGSize(width: 194, height: 120),
                seatPathSize: CGSize(width: pathWidth, height: 198),
                cornerRadius: 0,
                avatarSize: count <= 8 ? 40 : 36,
                showsNames: count <= 8
            )
        }

        let pathWidth = min(270, availableWidth - 40)
        return SeatingLayout(
            shape: .longRectangle,
            center: CGPoint(x: availableWidth / 2, y: 150),
            tabletopSize: CGSize(width: min(196, availableWidth - 100), height: 146),
            seatPathSize: CGSize(width: pathWidth, height: 214),
            cornerRadius: 48,
            avatarSize: 32,
            showsNames: false
        )
    }

    @ViewBuilder
    private func tabletop(for layout: SeatingLayout) -> some View {
        switch layout.shape {
        case .circle:
            styledTabletop(Circle(), size: layout.tabletopSize)
        case .oval:
            styledTabletop(Ellipse(), size: layout.tabletopSize)
        case .longRectangle:
            styledTabletop(
                RoundedRectangle(cornerRadius: 32, style: .continuous),
                size: layout.tabletopSize
            )
        }
    }

    private func styledTabletop<ShapeType: InsettableShape>(
        _ shape: ShapeType,
        size: CGSize
    ) -> some View {
        shape
            .fill(
                RadialGradient(
                    colors: [ForkensicsColor.raised, Color(hex: 0x0C0C0C)],
                    center: .center,
                    startRadius: 8,
                    endRadius: 110
                )
            )
            .overlay {
                shape.stroke(ForkensicsColor.orange.opacity(0.7), lineWidth: 2)
            }
            .overlay {
                shape
                    .inset(by: 9)
                    .stroke(ForkensicsColor.line, lineWidth: 1)
            }
            .frame(width: size.width, height: size.height)
    }

    private func seatPositions(for layout: SeatingLayout, count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }

        let samplePoints: [CGPoint]
        switch layout.shape {
        case .circle, .oval:
            samplePoints = ellipseSamplePoints(center: layout.center, size: layout.seatPathSize)
        case .longRectangle:
            samplePoints = roundedRectangleSamplePoints(
                center: layout.center,
                size: layout.seatPathSize,
                cornerRadius: layout.cornerRadius
            )
        }
        return evenlySpacedPoints(along: samplePoints, count: count)
    }

    private func ellipseSamplePoints(center: CGPoint, size: CGSize) -> [CGPoint] {
        let sampleCount = 720
        return (0...sampleCount).map { index in
            let angle = (-Double.pi / 2) + (Double(index) * 2 * Double.pi / Double(sampleCount))
            return CGPoint(
                x: center.x + CGFloat(cos(angle)) * size.width / 2,
                y: center.y + CGFloat(sin(angle)) * size.height / 2
            )
        }
    }

    private func roundedRectangleSamplePoints(
        center: CGPoint,
        size: CGSize,
        cornerRadius: CGFloat
    ) -> [CGPoint] {
        let left = center.x - size.width / 2
        let right = center.x + size.width / 2
        let top = center.y - size.height / 2
        let bottom = center.y + size.height / 2
        let radius = min(cornerRadius, min(size.width, size.height) / 2)
        var points = [CGPoint(x: center.x, y: top)]

        appendLine(to: CGPoint(x: right - radius, y: top), points: &points)
        appendArc(center: CGPoint(x: right - radius, y: top + radius), radius: radius, startAngle: -.pi / 2, endAngle: 0, points: &points)
        appendLine(to: CGPoint(x: right, y: bottom - radius), points: &points)
        appendArc(center: CGPoint(x: right - radius, y: bottom - radius), radius: radius, startAngle: 0, endAngle: .pi / 2, points: &points)
        appendLine(to: CGPoint(x: left + radius, y: bottom), points: &points)
        appendArc(center: CGPoint(x: left + radius, y: bottom - radius), radius: radius, startAngle: .pi / 2, endAngle: .pi, points: &points)
        appendLine(to: CGPoint(x: left, y: top + radius), points: &points)
        appendArc(center: CGPoint(x: left + radius, y: top + radius), radius: radius, startAngle: .pi, endAngle: 3 * .pi / 2, points: &points)
        appendLine(to: CGPoint(x: center.x, y: top), points: &points)
        return points
    }

    private func appendLine(to endpoint: CGPoint, points: inout [CGPoint]) {
        guard let start = points.last else { return }
        let steps = 40
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            points.append(
                CGPoint(
                    x: start.x + (endpoint.x - start.x) * progress,
                    y: start.y + (endpoint.y - start.y) * progress
                )
            )
        }
    }

    private func appendArc(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        points: inout [CGPoint]
    ) {
        let steps = 48
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let angle = startAngle + (endAngle - startAngle) * progress
            points.append(
                CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
            )
        }
    }

    private func evenlySpacedPoints(along points: [CGPoint], count: Int) -> [CGPoint] {
        guard count > 0, points.count > 1 else { return [] }

        var cumulativeDistances = [CGFloat](repeating: 0, count: points.count)
        for index in 1..<points.count {
            let deltaX = points[index].x - points[index - 1].x
            let deltaY = points[index].y - points[index - 1].y
            cumulativeDistances[index] = cumulativeDistances[index - 1] + sqrt(deltaX * deltaX + deltaY * deltaY)
        }

        guard let perimeter = cumulativeDistances.last, perimeter > 0 else {
            return Array(repeating: points[0], count: count)
        }

        var result: [CGPoint] = []
        var segmentIndex = 1
        for seatIndex in 0..<count {
            let targetDistance = perimeter * CGFloat(seatIndex) / CGFloat(count)
            while segmentIndex < cumulativeDistances.count - 1,
                  cumulativeDistances[segmentIndex] < targetDistance {
                segmentIndex += 1
            }

            let segmentStartDistance = cumulativeDistances[segmentIndex - 1]
            let segmentLength = cumulativeDistances[segmentIndex] - segmentStartDistance
            let progress = segmentLength > 0 ? (targetDistance - segmentStartDistance) / segmentLength : 0
            let start = points[segmentIndex - 1]
            let end = points[segmentIndex]
            result.append(
                CGPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                )
            )
        }
        return result
    }
}

struct ForkensicsTabBar: View {
    @Binding var selection: ForkensicsTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ForkensicsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: tab == .post ? 23 : 18, weight: tab == selection ? .semibold : .regular))
                        Text(tab.rawValue.uppercased())
                            .font(.system(size: 8, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(tab == selection ? ForkensicsColor.orange : ForkensicsColor.mutedText)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ForkensicsPressButtonStyle())
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(tab == selection ? .isSelected : [])
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(ForkensicsColor.line).frame(height: 1)
        }
    }
}

struct ForkensicsTextField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var secure = false
    var focus: Binding<Bool>? = nil

    @FocusState private var fieldFocused: Bool

    private var requestedFocus: Bool {
        focus?.wrappedValue ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(ForkensicsColor.secondaryText)
            if secure {
                SecureField(prompt, text: $text)
                    .textContentType(.password)
                    .focused($fieldFocused)
            } else {
                TextField(prompt, text: $text)
                    .focused($fieldFocused)
            }
        }
        .padding(14)
        .background(ForkensicsColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(ForkensicsColor.line, lineWidth: 1)
        }
        .onAppear {
            fieldFocused = requestedFocus
        }
        .onChange(of: requestedFocus) { _, newValue in
            fieldFocused = newValue
        }
        .onChange(of: fieldFocused) { _, newValue in
            guard focus?.wrappedValue != newValue else { return }
            focus?.wrappedValue = newValue
        }
    }
}
