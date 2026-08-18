import ActivityKit
import OSLog
import UIKit

final class ForkensicsLiveActivityService {
    static let shared = ForkensicsLiveActivityService()

    private let logger = Logger(
        subsystem: "com.forkensics.prototype",
        category: "live-activities"
    )

    private init() {}

    func startCaseActivity(for item: WireframePostedCase, posterName: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled")
            return
        }

        guard let thumbnailData = makeCompactThumbnail(from: item.photoData) else {
            logger.error("Could not create Live Activity thumbnail")
            return
        }

        // Keep the newest mystery prominent instead of allowing old activities to
        // compete for the Dynamic Island and Lock Screen position.
        for activity in Activity<ForkensicsCaseActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let attributes = ForkensicsCaseActivityAttributes(
            caseID: item.id.uuidString,
            caseTitle: item.title,
            posterName: posterName,
            revealAt: item.deadlineAt,
            thumbnailData: thumbnailData
        )
#if DEBUG
        UserDefaults.standard.set(
            thumbnailData.count,
            forKey: "Forkensics.debugLiveActivityAttemptedPhotoBytes"
        )
#endif
        let state = ForkensicsCaseActivityAttributes.ContentState(status: "CASE ACTIVE")
        let content = ActivityContent(
            state: state,
            staleDate: item.deadlineAt,
            relevanceScore: 100
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            logger.info(
                "Started case Live Activity \(activity.id, privacy: .public) with \(thumbnailData.count) photo bytes"
            )
#if DEBUG
            UserDefaults.standard.set(activity.id, forKey: "Forkensics.debugLiveActivityID")
            UserDefaults.standard.set(thumbnailData.count, forKey: "Forkensics.debugLiveActivityPhotoBytes")
            UserDefaults.standard.removeObject(forKey: "Forkensics.debugLiveActivityError")
#endif
        } catch {
            logger.error("Live Activity failed: \(error.localizedDescription, privacy: .public)")
#if DEBUG
            UserDefaults.standard.set(error.localizedDescription, forKey: "Forkensics.debugLiveActivityError")
#endif
        }
    }

    private func makeCompactThumbnail(from data: Data) -> Data? {
        guard let source = UIImage(data: data) else { return nil }

        // ActivityKit limits all static and dynamic activity data to 4 KB. Leave
        // enough room for the case metadata while preserving a recognizable photo.
        let candidates: [(side: CGFloat, quality: CGFloat)] = [
            (80, 0.30),
            (72, 0.26),
            (64, 0.22),
            (56, 0.18),
            (48, 0.16)
        ]

        for candidate in candidates {
            let image = squareCrop(source, side: candidate.side)
            if let jpeg = image.jpegData(compressionQuality: candidate.quality),
               jpeg.count <= 1_450 {
                return jpeg
            }
        }

        return squareCrop(source, side: 40).jpegData(compressionQuality: 0.12)
    }

    private func squareCrop(_ image: UIImage, side: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            let scale = max(side / image.size.width, side / image.size.height)
            let drawSize = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            image.draw(
                in: CGRect(
                    x: (side - drawSize.width) / 2,
                    y: (side - drawSize.height) / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
            )
        }
    }
}
