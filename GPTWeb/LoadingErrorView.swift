import UIKit

final class LoadingErrorView: UIView {
    var onRetry: (() -> Void)?
    var onOpenInSafari: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let safariButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(title: String, message: String, canRetry: Bool = true) {
        titleLabel.text = title
        messageLabel.text = message
        retryButton.isHidden = !canRetry
        isHidden = false
        accessibilityViewIsModal = true
    }

    func hide() {
        isHidden = true
        accessibilityViewIsModal = false
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .systemBackground
        isHidden = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "wifi.exclamationmark")
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var retryConfiguration = UIButton.Configuration.filled()
        retryConfiguration.title = "重试"
        retryConfiguration.cornerStyle = .large
        retryConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 12,
            leading: 28,
            bottom: 12,
            trailing: 28
        )
        retryButton.configuration = retryConfiguration
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.accessibilityIdentifier = "retryButton"

        var safariConfiguration = UIButton.Configuration.plain()
        safariConfiguration.title = "用 Safari 打开"
        safariButton.configuration = safariConfiguration
        safariButton.addTarget(self, action: #selector(safariTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            iconView,
            titleLabel,
            messageLabel,
            retryButton,
            safariButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(20, after: messageLabel)

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -18),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    @objc private func retryTapped() {
        onRetry?()
    }

    @objc private func safariTapped() {
        onOpenInSafari?()
    }
}

