import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct ForkensicsLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ForkensicsCaseLiveActivity()
    }
}

struct ForkensicsCaseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ForkensicsCaseActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(caseURL(context.attributes.caseID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ForkensicsMark(size: 34)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    countdown(to: context.attributes.revealAt, font: .headline)
                        .foregroundStyle(ForkensicsActivityColor.orange)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(context.state.status)
                                .font(.caption2.bold())
                                .tracking(1.3)
                                .foregroundStyle(ForkensicsActivityColor.orange)
                            Text(context.attributes.caseTitle)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Tap to investigate")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        Spacer(minLength: 6)
                        CaseThumbnail(data: context.attributes.thumbnailData, size: 52)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                CaseThumbnail(data: context.attributes.thumbnailData, size: 22)
            } compactTrailing: {
                countdown(to: context.attributes.revealAt, font: .caption2.bold())
                    .foregroundStyle(ForkensicsActivityColor.orange)
                    .frame(maxWidth: 52)
            } minimal: {
                CaseThumbnail(data: context.attributes.thumbnailData, size: 20)
            }
            .widgetURL(caseURL(context.attributes.caseID))
            .keylineTint(ForkensicsActivityColor.orange)
        }
    }

    private func lockScreenView(
        _ context: ActivityViewContext<ForkensicsCaseActivityAttributes>
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    ForkensicsMark(size: 25)
                    Text("FORKENSICS")
                        .font(.caption.bold())
                        .tracking(2)
                        .foregroundStyle(.white)
                }

                Text(context.attributes.caseTitle)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("From \(context.attributes.posterName)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: "timer")
                    Text("REVEALS IN")
                        .font(.caption2.bold())
                        .tracking(1)
                    countdown(to: context.attributes.revealAt, font: .headline)
                }
                .foregroundStyle(ForkensicsActivityColor.orange)
            }

            Spacer(minLength: 4)

            CaseThumbnail(data: context.attributes.thumbnailData, size: 108)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    private func countdown(to date: Date, font: Font) -> some View {
        Text(timerInterval: Date.now...max(date, Date.now), countsDown: true)
            .font(font.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private func caseURL(_ caseID: String) -> URL? {
        URL(string: "forkensics://case/\(caseID)")
    }
}

private enum ForkensicsActivityColor {
    static let orange = Color(red: 1, green: 0.34, blue: 0.035)
}

private struct ForkensicsMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height)
            let whiteStroke = StrokeStyle(
                lineWidth: scale * 0.075,
                lineCap: .round,
                lineJoin: .round
            )
            let orangeStroke = StrokeStyle(
                lineWidth: scale * 0.062,
                lineCap: .round,
                lineJoin: .round
            )

            var lens = Path()
            lens.addEllipse(
                in: CGRect(
                    x: scale * 0.07,
                    y: scale * 0.07,
                    width: scale * 0.66,
                    height: scale * 0.66
                )
            )
            context.stroke(lens, with: .color(.white), style: whiteStroke)

            var handle = Path()
            handle.move(to: CGPoint(x: scale * 0.65, y: scale * 0.65))
            handle.addLine(to: CGPoint(x: scale * 0.92, y: scale * 0.92))
            context.stroke(handle, with: .color(.white), style: whiteStroke)

            var fork = Path()
            for x in [0.29, 0.37, 0.45, 0.53] {
                fork.move(to: CGPoint(x: scale * x, y: scale * 0.18))
                fork.addLine(to: CGPoint(x: scale * x, y: scale * 0.36))
            }
            fork.move(to: CGPoint(x: scale * 0.29, y: scale * 0.36))
            fork.addQuadCurve(
                to: CGPoint(x: scale * 0.41, y: scale * 0.48),
                control: CGPoint(x: scale * 0.31, y: scale * 0.47)
            )
            fork.addLine(to: CGPoint(x: scale * 0.41, y: scale * 0.72))
            fork.move(to: CGPoint(x: scale * 0.53, y: scale * 0.36))
            fork.addQuadCurve(
                to: CGPoint(x: scale * 0.41, y: scale * 0.48),
                control: CGPoint(x: scale * 0.51, y: scale * 0.47)
            )
            context.stroke(fork, with: .color(ForkensicsActivityColor.orange), style: orangeStroke)

            var point = Path()
            point.move(to: CGPoint(x: scale * 0.33, y: scale * 0.69))
            point.addQuadCurve(
                to: CGPoint(x: scale * 0.41, y: scale * 0.90),
                control: CGPoint(x: scale * 0.31, y: scale * 0.79)
            )
            point.addQuadCurve(
                to: CGPoint(x: scale * 0.49, y: scale * 0.69),
                control: CGPoint(x: scale * 0.51, y: scale * 0.79)
            )
            point.closeSubpath()
            context.fill(point, with: .color(ForkensicsActivityColor.orange))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct CaseThumbnail: View {
    let data: Data
    let size: CGFloat

    var body: some View {
        Group {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    ForkensicsActivityColor.orange.opacity(0.22)
                    Image(systemName: "fork.knife")
                        .foregroundStyle(ForkensicsActivityColor.orange)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.17, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }
}
