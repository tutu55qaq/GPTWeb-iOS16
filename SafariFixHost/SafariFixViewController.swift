import UIKit

final class SafariFixViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.text = "ChatGPT Safari 滚动修复"

        let statusLabel = UILabel()
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .systemBlue
        statusLabel.text = "扩展已随本应用安装"

        let instructions = UILabel()
        instructions.font = .preferredFont(forTextStyle: .body)
        instructions.adjustsFontForContentSizeCategory = true
        instructions.numberOfLines = 0
        instructions.text = """
        1. 打开“设置 → Safari → 扩展”

        2. 启用“ChatGPT Work 滚动修复”

        3. 允许访问 chatgpt.com

        4. 重新打开 Safari 并刷新 ChatGPT

        5. 进入 Work 对话，纵向滑动后长按右上角蓝点

        注意：这个扩展宿主必须使用正常的 Apple 开发者证书与匹配的 Provisioning Profile 安装，不能通过 TrollStore 注册。
        """

        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = "在 Safari 中打开 ChatGPT"
        buttonConfiguration.cornerStyle = .large
        let openButton = UIButton(configuration: buttonConfiguration)
        openButton.addTarget(
            self,
            action: #selector(openChatGPT),
            for: .touchUpInside
        )

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            statusLabel,
            instructions,
            openButton
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 24

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(stack)
        view.addSubview(scrollView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor
            ),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor
            ),
            stack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 32
            ),
            stack.leadingAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.trailingAnchor,
                constant: -24
            ),
            stack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -32
            )
        ])
    }

    @objc
    private func openChatGPT() {
        guard let url = URL(string: "https://chatgpt.com/") else { return }
        UIApplication.shared.open(url)
    }
}
