# GPT Web for iOS 16

一个面向个人侧载的轻量级 `WKWebView` 客户端，默认打开
`https://chatgpt.com/`。工程最低支持 iOS 16.0，并针对 iOS 16.3 与
iPhone 13 Pro Max（428 pt 宽度、刘海安全区、底部 Home Indicator、120 Hz
ProMotion）进行了适配。

> 这是非官方项目，与 OpenAI 没有隶属或背书关系。它不包含 OpenAI 商标图标，
> 不会读取、上传或记录账号、Cookie 和对话内容。

## 主要特性

- 使用持久化 `WKWebsiteDataStore`，登录状态保留在应用自己的 WebKit 沙盒中。
- 使用 iOS 16.3 Mobile Safari User-Agent，降低网页对嵌入式浏览器的误判。
- 仅对 `chatgpt.com`、OpenAI 登录域和登录所需身份提供商保持站内导航；普通外链在
  `SFSafariViewController` 中打开。
- WebContent 进程被系统终止后自动恢复，并对离线、超时和加载失败提供明确的重试界面。
- 支持 ChatGPT 网页触发的文件下载、系统分享、文件上传、麦克风和摄像头授权。
- 输入区采用 16 pt 最小字号，避免聚焦编辑框时网页自动放大；交互控件启用
  `touch-action: manipulation`，减少误触延迟。
- 保留 WebKit 原生惯性滚动，不再接管整页触摸事件；右侧常驻可拖动滚动条用于
  Work 模式等旧版 WebKit 无法正常触摸滚动的嵌套对话。
- 键盘可交互收起、返回手势、加载进度条、深色模式与 120 Hz 刷新率。
- 不注入 API Key，不读取或上传对话文本，不拦截网络请求。自定义滚动条只检查元素的
  尺寸、滚动位置和父子关系。

## 在 Mac 上直接生成未签名 IPA

要求：macOS、Xcode 14.1 或更高版本（Xcode 14.2 与 iOS 16.3 SDK 最匹配）。

```bash
cd GPTWeb
chmod +x scripts/build-ipa.sh
./scripts/build-ipa.sh
```

输出文件：

```text
build/GPTWeb-unsigned.ipa
```

需要自定义 Bundle ID 时：

```bash
BUNDLE_ID=com.yourname.gptweb ./scripts/build-ipa.sh
```

生成的 IPA 不含签名和描述文件，你可以用自己的方式签名安装。

## 用 Xcode 构建

1. 打开 `GPTWeb.xcodeproj`。
2. 选择 `GPTWeb` Target，在 Signing & Capabilities 中选择你的 Team 并修改
   Bundle Identifier。
3. 选择真机后运行，或使用 Product → Archive。

## 用 GitHub Actions 生成 IPA

将整个目录提交到 GitHub，打开 Actions，运行 **Build unsigned IPA**。
完成后在该次运行的 Artifacts 中下载 `GPTWeb-unsigned-ipa`。工作流不需要证书或
Apple 账号。

## 登录提示

邮箱登录通常最稳定。部分第三方 OAuth 提供商会主动拒绝嵌入式浏览器；这是提供商的
安全策略，不是 WebView 能可靠绕过的限制。如果 Google、Apple 或 Microsoft 登录页
拒绝继续，请先在 Safari 登录 ChatGPT，或改用邮箱登录。Safari 与本应用的 Cookie
彼此隔离，因此 Safari 的登录态不会自动复制到本应用。

## 性能说明

这个项目能减少 Safari 标签页争用、保留独立的 WebKit 进程与 Cookie，并在网页进程
被系统回收后自动恢复，所以通常比长期堆积标签页的 Safari 更稳定。但它仍使用 iOS
16.3 自带的 WebKit 引擎，无法修复 `chatgpt.com` 未来可能使用而旧 WebKit 不支持的
JavaScript/CSS 特性，也不能保证一定快于一个全新、无其他标签页的 Safari。

## 安全边界

- 账号和会话只保存在系统管理的 WebKit 数据仓库。
- 下载先进入应用临时目录，调出系统分享面板后由你决定保存位置。
- 媒体权限只允许 ChatGPT/OpenAI 第一方安全源发起，并仍由 iOS 显示系统授权提示。
- 工程未启用任意 HTTP 加载，网页主入口使用 HTTPS。

## 验证

在任意环境可运行静态检查：

```bash
./scripts/validate-project.sh
```

真正的 Swift 编译和 IPA 打包必须在 macOS/Xcode 上完成，因为 Apple 的 iOS SDK
不为 Linux 提供。
