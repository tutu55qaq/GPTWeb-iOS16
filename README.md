# ChatGPT WebView for iOS 16

一个面向个人侧载的轻量级 `WKWebView` 客户端，默认打开
`https://chatgpt.com/`。工程最低支持 iOS 16.0，并针对 iOS 16.3 与
iPhone 13 Pro Max（428 pt 宽度、刘海安全区、底部 Home Indicator、120 Hz
ProMotion）进行了适配。

> 这是用于个人侧载的非官方 WebView 客户端，与 OpenAI 没有隶属或背书关系。
> 应用显示名与图标取自官方 ChatGPT iOS 客户端，便于替代无法安装的官方客户端；
> 工程不会读取、上传或记录账号、Cookie 和对话内容。

## 主要特性

- 使用持久化 `WKWebsiteDataStore`，登录状态保留在应用自己的 WebKit 沙盒中。
- 使用 iOS 16.3 Mobile Safari User-Agent，降低网页对嵌入式浏览器的误判。
- 仅对 `chatgpt.com`、OpenAI 登录域和登录所需身份提供商保持站内导航；普通外链在
  `SFSafariViewController` 中打开。
- WebContent 进程被系统终止后自动恢复，并对离线、超时和加载失败提供明确的重试界面。
- 支持 ChatGPT 网页触发的文件下载、系统分享、文件上传、麦克风和摄像头授权。
- 输入区采用 16 pt 最小字号，避免聚焦编辑框时网页自动放大；交互控件启用
  `touch-action: manipulation`，减少误触延迟。
- 保留 WebKit 原生惯性滚动，不接管页面的滚动手势；检测到 Work 嵌套对话的纵向
  滑动后，右上角会短暂出现一个蓝色修复圆点。长按圆点会对当前容器执行一次局部
  修复，随后继续使用原生滑动与 iOS 原生滚动条，静止时圆点自动隐藏。
- 键盘可交互收起、返回手势、加载进度条、深色模式与 120 Hz 刷新率。
- 不注入 API Key，不读取或上传对话文本，不拦截网络请求。滚动修复逻辑只检查元素的
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

使用 TrollStore 更新时保持相同的 Bundle ID 并直接覆盖安装，不要先卸载；这样可以
沿用现有应用数据容器和 WebKit 登录状态。

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

## Work 模式滚动修复原理

### 它修复的是什么

这个功能不会修改、替换或破解 iOS 的 WebKit 内核。它是由 `WKUserScript` 注入
`chatgpt.com` 页面及其子 Frame 的局部 DOM/CSS 兼容补丁。

在 iOS 16.3 上，ChatGPT Work 页面可能出现这样的状态：手指触摸的是内部消息列表，
但旧版 WebKit 没有把这个嵌套元素继续当作可触摸滚动区域，手势被交给外层页面，
表现为整个页面轻微回弹，而消息列表不移动。这也解释了为什么同一问题可能同时出现
在本应用和系统 Safari 中——两者使用的是同一代 WebKit。

目前没有证据能把根因完全归结为单一的 Safari Bug；更准确的说法是，ChatGPT Work
当前的嵌套布局、动态 DOM 和 iOS 16.3 WebKit 的滚动层/手势判定组合在一起触发了
兼容问题。

### 长按圆点时发生了什么

1. **被动检测手势。** 页面上的 `touchstart`/`touchmove` 监听器使用
   `passive: true`，只在检测到纵向滑动时显示右上角圆点，不取消页面原本的触摸事件。
2. **锁定实际消息容器。** 脚本从触摸位置向上查找有真实滚动范围
   （`scrollHeight > clientHeight`）的父元素，优先选择
   `overflow-y: auto/scroll/overlay` 的原生滚动容器；对 Work 中使用
   `hidden/clip` 的异常容器，再结合 `main`、`dialog`、滚动类名、可见面积和滚动范围
   评分。外层页面的橡皮筋回弹不会覆盖已经选中的内部容器。
3. **等待明确确认。** 只有在圆点上持续按住约 360 ms 才执行修复，普通浏览、普通
   滑动和误触不会改写页面样式。
4. **重新声明滚动条件。** 脚本只对选中的元素写入以下内联样式：

   ```css
   overflow-y: auto !important;
   -webkit-overflow-scrolling: auto !important;
   overscroll-behavior-y: contain !important;
   touch-action: pan-y !important;
   min-height: 0 !important;
   ```

   - `overflow-y` 让该元素明确成为纵向滚动容器。
   - `-webkit-overflow-scrolling` 的重新赋值促使旧 WebKit 更新该元素的滚动层状态。
   - `overscroll-behavior-y` 尽量避免手势继续传给外层页面。
   - `touch-action` 明确允许原生纵向平移手势。
   - `min-height: 0` 修正 Flex/Grid 子项因默认最小高度而撑开、失去内部滚动范围的
     常见情况。
5. **刷新布局后交还原生滚动。** 读取一次 `offsetHeight`，让 WebKit 在下一次触摸
   前提交新的布局和滚动层状态。脚本随后停止介入，由 iOS 原生触摸滚动、惯性和系统
   滚动条继续工作。

脚本不会写入 `scrollTop`，不会模拟手指位移，也没有自定义惯性动画，因此不会再产生
此前自定义滚动条“一顿一顿”的手感。修复成功的元素会写入
`data-gptweb-scroll-repaired="true"` 标记，避免重复弹出圆点；如果 ChatGPT 后续
重新创建了 Work 消息容器，新元素没有这个标记，纵向滑动时圆点会再次出现，可重新
长按修复。

对应实现位于 `GPTWeb/WebViewController.swift` 的 `workRepairDotScript`，无
`scrollTop` 接管、目标锁定和持久修复行为由 `scripts/test-scroll-fix.js` 做静态
回归检查。

### 能否在 iPhone 的 Safari 中使用

可以使用同一思路，但本应用不能直接修改系统 Safari 中已经打开的网页。iOS 的应用
沙盒把 `WKWebView` 和 Safari 标签页隔离，本应用注入的 `WKUserScript` 只对本应用
自己的 WebView 生效。

在 Safari 中有两种实现方式：

- **推荐：Safari Web Extension。** iOS 15 起支持 Safari Web Extension。可以把
  同一段修复逻辑作为只匹配 `https://chatgpt.com/*` 的 content script，在页面和
  子 Frame 加载后自动注入。安装包含扩展的 App 后，需要在
  “设置 → Safari → 扩展”中启用，并允许它访问 `chatgpt.com`。这是长期使用最可靠
  的方案，也能继续保持 Safari 自己的 Cookie、登录状态、下载和标签页功能。
- **临时方案：JavaScript 书签。** 可以把简化后的修复函数保存为
  `javascript:` 书签，需要时手动运行。它不持久，页面刷新、Work 重建 DOM 后需要
  再运行；而且书签脚本对不同 Frame 的访问和执行时机不如正式扩展稳定，因此更适合
  验证，不适合长期使用。

Safari Web Extension 仍然不能修复 WebKit 内核本身；它只是获得 Safari 授权后，
在 `chatgpt.com` 内自动执行相同的页面级兼容补丁。

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
