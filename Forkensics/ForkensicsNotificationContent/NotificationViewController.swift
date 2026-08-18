import UIKit
import UserNotifications
import UserNotificationsUI

final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let actionLabel = UILabel()
    private let photoView = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        titleLabel.text = content.title
        subtitleLabel.text = content.subtitle
        bodyLabel.text = content.body
        loadPhoto(from: content.attachments.first)
    }

    private func buildLayout() {
        view.backgroundColor = UIColor(red: 0.035, green: 0.035, blue: 0.035, alpha: 1)
        view.layer.cornerRadius = 18
        view.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        subtitleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        subtitleLabel.textColor = UIColor(red: 1, green: 0.35, blue: 0.04, alpha: 1)
        subtitleLabel.numberOfLines = 2

        bodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
        bodyLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        bodyLabel.numberOfLines = 3

        actionLabel.text = "Tap to investigate →"
        actionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        actionLabel.textColor = UIColor.white.withAlphaComponent(0.58)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, bodyLabel, actionLabel])
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 5
        textStack.setCustomSpacing(9, after: subtitleLabel)

        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        photoView.backgroundColor = UIColor.white.withAlphaComponent(0.06)

        let layout = UIStackView(arrangedSubviews: [textStack, photoView])
        layout.axis = .horizontal
        layout.alignment = .fill
        layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(layout)

        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            layout.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            layout.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            layout.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            photoView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.39)
        ])

        preferredContentSize = CGSize(width: 360, height: 176)
    }

    private func loadPhoto(from attachment: UNNotificationAttachment?) {
        guard let attachment else { return }

        let canAccess = attachment.url.startAccessingSecurityScopedResource()
        defer {
            if canAccess {
                attachment.url.stopAccessingSecurityScopedResource()
            }
        }

        photoView.image = UIImage(contentsOfFile: attachment.url.path)
    }
}
