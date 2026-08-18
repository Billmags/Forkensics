import Foundation
import OSLog
import UIKit
import UserNotifications

extension Notification.Name {
    static let forkensicsOpenCase = Notification.Name("Forkensics.openCaseFromNotification")
}

enum ForkensicsNotificationKeys {
    static let caseID = "case_id"
    static let pendingCaseID = "Forkensics.pendingNotificationCaseID"
}

final class ForkensicsNotificationService {
    static let shared = ForkensicsNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.forkensics.prototype", category: "notifications")

    private init() {}

    func scheduleNewCase(
        _ item: WireframePostedCase,
        posterName: String,
        deliveryDelay: TimeInterval = 1,
        sendBanner: Bool = false
    ) async {
        await ForkensicsLiveActivityService.shared.startCaseActivity(
            for: item,
            posterName: posterName
        )

        // The Live Activity is the primary case alert: it already carries the
        // photo, countdown, and deep link. Avoid presenting a duplicate banner.
        guard sendBanner else { return }

        guard await requestPermission() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Can you crack this one?"
        content.subtitle = item.title
        content.body = "From \(posterName) — tap to investigate."
        content.sound = .default
        content.badge = 1
        content.categoryIdentifier = "FORKENSICS_NEW_CASE"
        content.threadIdentifier = "case-\(item.id.uuidString)"
        content.userInfo = [ForkensicsNotificationKeys.caseID: item.id.uuidString]

        if let attachment = makePhotoAttachment(for: item) {
            content.attachments = [attachment]
            logger.info("Prepared notification attachment type=\(attachment.type, privacy: .public)")
        } else {
            logger.error("Could not prepare notification attachment for case \(item.id.uuidString, privacy: .public)")
        }

        let request = UNNotificationRequest(
            identifier: "new-case-\(item.id.uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, deliveryDelay),
                repeats: false
            )
        )

        do {
            try await center.add(request)
            logger.info("Scheduled case notification with \(content.attachments.count) attachment(s)")
#if DEBUG
            UserDefaults.standard.set(content.attachments.count, forKey: "Forkensics.debugScheduledAttachmentCount")
            let requestIdentifier = request.identifier
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let delivered = await self.center.deliveredNotifications()
                let attachmentCount = delivered.first {
                    $0.request.identifier == requestIdentifier
                }?.request.content.attachments.count ?? -1
                UserDefaults.standard.set(
                    attachmentCount,
                    forKey: "Forkensics.debugDeliveredAttachmentCount"
                )
                self.logger.info("Delivered case notification has \(attachmentCount) attachment(s)")
            }
#endif
        } catch {
            logger.error("Failed to schedule case notification: \(error.localizedDescription, privacy: .public)")
#if DEBUG
            UserDefaults.standard.set(error.localizedDescription, forKey: "Forkensics.debugNotificationError")
#endif
        }
    }

    private func requestPermission() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func makePhotoAttachment(for item: WireframePostedCase) -> UNNotificationAttachment? {
        guard let image = UIImage(data: item.photoData),
              let jpegData = image.preparingThumbnail(of: CGSize(width: 1200, height: 1200))?
                .jpegData(compressionQuality: 0.82) ?? image.jpegData(compressionQuality: 0.82),
              let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        let attachmentDirectory = cachesDirectory
            .appendingPathComponent("ForkensicsNotificationPhotos", isDirectory: true)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        let attachmentURL = attachmentDirectory.appendingPathComponent("case-photo.jpg")

        do {
            try fileManager.createDirectory(
                at: attachmentDirectory,
                withIntermediateDirectories: true
            )
            try jpegData.write(to: attachmentURL, options: .atomic)
            guard fileManager.isReadableFile(atPath: attachmentURL.path),
                  (try attachmentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                logger.error("Notification attachment file was not readable after writing")
                return nil
            }

            return try UNNotificationAttachment(
                identifier: "case-photo",
                url: attachmentURL,
                options: [
                    UNNotificationAttachmentOptionsThumbnailHiddenKey: NSNumber(value: false),
                    UNNotificationAttachmentOptionsThumbnailClippingRectKey:
                        CGRectCreateDictionaryRepresentation(
                            CGRect(x: 0, y: 0, width: 1, height: 1)
                        )
                ]
            )
        } catch {
            logger.error("Notification attachment creation failed: \(error.localizedDescription, privacy: .public)")
#if DEBUG
            UserDefaults.standard.set(error.localizedDescription, forKey: "Forkensics.debugAttachmentError")
#endif
            return nil
        }
    }
}

final class ForkensicsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: "FORKENSICS_NEW_CASE",
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ForkensicsTestRichNotification"),
           let image = UIImage(named: "StreetTacos"),
           let photoData = image.jpegData(compressionQuality: 0.9) {
            notificationCenter.removeAllPendingNotificationRequests()
            notificationCenter.removeAllDeliveredNotifications()
            let sample = WireframePostedCase(
                photoData: photoData,
                title: "South of the Border",
                dish: "Street Tacos",
                restaurant: "Raul's",
                location: "Fort Myers, FL",
                clue: "",
                tableNames: ["Schroeder Table"],
                durationHours: 2,
                posterPlayerID: "noah"
            )
            Task {
                await ForkensicsNotificationService.shared.scheduleNewCase(
                    sample,
                    posterName: "Noah Schroeder",
                    deliveryDelay: 8
                )
            }
        }
#endif
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let caseID = response.notification.request.content.userInfo[ForkensicsNotificationKeys.caseID] as? String else {
            return
        }

        UserDefaults.standard.set(caseID, forKey: ForkensicsNotificationKeys.pendingCaseID)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .forkensicsOpenCase,
                object: nil,
                userInfo: [ForkensicsNotificationKeys.caseID: caseID]
            )
        }
    }
}
