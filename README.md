# ChatGPT WebView for iOS 16

本项目主要解决 iPhone 13 Pro Max（iOS 16.3）访问 ChatGPT Work 时内部对话无法
上下滑动、手势只让整个页面轻微回弹的问题，同时保留普通聊天的原生惯性滚动。它是
一个最低支持 iOS 16.0 的个人侧载 `WKWebView` 客户端，并提供可作用于系统 Safari
的独立 Web Extension 宿主。本项目完全由 GPT 全程通过移动端编写、调试与维护，由
GPT 管理 GitHub 仓库并接管 GitHub Actions 云端编译、校验和发布 IPA。

> 这是用于个人侧载的非官方 WebView 客户端，与 OpenAI 没有隶属或背书关系。
> 应用显示名与图标取自官方 ChatGPT iOS 客户端，便于替代无法安装的官方客户端；
> 工程不会读取、上传或记录账号、Cookie 和对话内容。

## 主要特性

- 使用持久化 `WKWebsiteDataStore`，登录状态保留在应用自己的 WebKit 沙盒中。
- 冷启动固定进入 `https://chatgpt.com/` 的空白新对话，不再自动恢复最后打开的长
  对话；只切到后台再回来时仍保持当前页面。
- 关闭 WKWebView 默认的左缘后退手势：从屏幕左缘向右滑会打开聊天列表，列表打开后
  向左滑会收起。手势监听保持被动，不取消上下滚动和 Work 页面触摸。
- 使用 iOS 16.3 Mobile Safari User-Agent，降低网页对嵌入式浏览器的误判。
- 仅对 `chatgpt.com`、OpenAI 登录域和登录所需身份提供商保持站内导航；普通外链在
  `SFSafariViewController` 中打开。
- WebContent 进程被系统终止后自动恢复，并对离线、超时和加载失败提供明确的重试界面。
- 支持 ChatGPT 网页触发的文件下载、系统分享、文件上传、麦克风和摄像头授权。
- 注册为 PDF、图片、音视频、文本和常见文档的“在 ChatGPT 中打开”目标。由其他 App
  或系统“文件”打开的文件会先由 iOS 复制到应用自己的 Inbox，再复制到缓存并通过
  网页真实的附件输入框直接加入当前聊天；如果网页结构变化或文件较大，则回退到
  ChatGPT 原生的文件选择流程。
- 不再接管从系统“文件”长按拖入的交互；iOS 16.3 的 WKWebView 在该路径中可能闪退，
  请使用系统分享菜单中的“打开方式 → ChatGPT”。
- 输入区采用 16 pt 最小字号，避免聚焦编辑框时网页自动放大；交互控件启用
  `touch-action: manipulation`，减少误触延迟。
- 保留 WebKit 原生惯性滚动，不接管页面的滚动手势；检测到 Work 嵌套对话的纵向
  滑动后，右上角会短暂出现一个蓝色修复圆点。长按圆点会对当前容器执行一次局部
  修复，随后继续使用原生滑动与 iOS 原生滚动条，静止时圆点自动隐藏。
- 配套的独立 `SafariFixHost` IPA 内嵌 `SafariExtension.appex`；使用正常 Apple
  开发者签名安装并获得 `chatgpt.com` 网站权限后，会在系统 Safari 的主页面和
  子 Frame 中提供同一套 Work 滚动修复圆点。
- TrollStore 版主程序不再嵌入 Safari 扩展，避免系统显示“插件已不可用”；它保持
  原 Bundle ID，可直接覆盖旧版本并保留 WebKit 登录状态。
- 键盘可交互收起、返回手势、加载进度条、深色模式与 ProMotion 自适应高刷新率。
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
build/SafariFixHost-unsigned.ipa
```

需要自定义两个宿主的 Bundle ID 时：

```bash
BUNDLE_ID=com.yourname.gptweb \
SAFARI_FIX_BUNDLE_ID=com.yourname.gptweb.safarifix \
./scripts/build-ipa.sh
```

两个 IPA 都不含签名和描述文件。`GPTWeb-unsigned.ipa` 供 TrollStore 安装；
`SafariFixHost-unsigned.ipa` 必须用正常 Apple 开发者签名安装，且宿主和内嵌
`.appex` 都要拥有匹配的 App ID 与 Provisioning Profile。

使用 TrollStore 更新时保持相同的 Bundle ID 并直接覆盖安装，不要先卸载；这样可以
沿用现有应用数据容器和 WebKit 登录状态。

## 在 Safari 中启用滚动修复扩展

Safari Web Extension 不能作为一个裸 `.appex` 单独安装，所以本项目把它嵌入独立的
`SafariFixHost-unsigned.ipa`。这个 IPA **不能使用 TrollStore 安装**：TrollStore
将应用作为系统应用安装，iOS 不会把其中的 Safari Web Extension 注册到 Safari，
典型表现就是打开宿主时提示“插件已不可用”，并且“设置 → Safari → 扩展”中完全
看不到它。

请使用 Xcode，或确实支持对宿主和内嵌 `.appex` 分别重签并生成匹配描述文件的侧载
工具，安装 `SafariFixHost-unsigned.ipa`。安装成功后：

1. 打开“设置 → Safari → 扩展”。
2. 选择“ChatGPT Work 滚动修复”并启用。
3. 将 `chatgpt.com` 的网站访问权限设为“允许”。
4. 完全退出并重新打开 Safari，刷新已经打开的 ChatGPT 标签页。
5. 进入 Work 对话并做一次纵向滑动；右上角圆点出现后长按约 360 ms，看到圆点
   放大并出现光圈后松手。

如果扩展仍不在设置中，先确认安装方式不是 TrollStore，再检查签名后的 IPA 中宿主
Bundle ID 为 `com.example.gptweb.safarifix`，扩展 Bundle ID 为
`com.example.gptweb.safarifix.SafariExtension`，并确认两个 Bundle ID 都有各自
匹配的签名和描述文件。

扩展使用 Safari 自己的 Cookie 与登录状态，不会读取或复制本应用 WebView 的 Cookie。
它不拦截网络请求，只在 ChatGPT 页面中检查元素尺寸、滚动范围和父子关系，并为用户
明确选中的容器写入滚动修复 CSS。

这个限制不是本项目清单文件造成的。TrollStore 项目中已经长期存在同类报告，包括
iOS 16.2 / TrollStore 2 下 Safari 扩展不出现在设置中的
[#843](https://github.com/opa334/TrollStore/issues/843)，以及更早的
[#74](https://github.com/opa334/TrollStore/issues/74)、
[#209](https://github.com/opa334/TrollStore/issues/209) 和
[#615](https://github.com/opa334/TrollStore/issues/615)。Apple 的
[Safari Web Extension 文档](https://developer.apple.com/documentation/safariservices/safari-web-extensions)
也要求扩展随原生 App 打包和签名。

## 更新主程序与刷新旧图标

主程序继续使用 `com.example.gptweb`。在 TrollStore 中直接覆盖安装
`GPTWeb-unsigned.ipa`，不要卸载旧版，这样应用数据容器、Cookie 和登录状态都会
保留。

1. 覆盖安装 1.2.6。
2. 在 TrollStore 设置中执行 **Rebuild Icon Cache**。
3. 结束多任务页面中旧的 ChatGPT 卡片，再重新打开应用。
4. 如果多任务左上角仍是旧图标，执行一次 Respring；仍未刷新时再重启设备。

1.2.1 起把 Asset Catalog 的图标集缓存键从 `AppIcon` 改为 `ChatGPTIcon`，同时显式
写入 `CFBundleIconName`。这会让新构建引用新的图标记录；但 iOS 的 SpringBoard 和
多任务快照仍可能保留旧缓存，所以覆盖安装后仍需要执行上面的缓存刷新。

## 从其他 App 直接加入文件

1. 在“文件”、邮件、网盘或 PDF 阅读器中选择文件。
2. 选择“在其他应用中打开”或系统分享菜单中的“打开方式”。
3. 选择 **ChatGPT**。
4. 应用会把文件复制进自己的缓存，并尝试直接触发 ChatGPT 网页的附件输入事件。
   成功后，文件会像官方 App 一样直接出现在聊天输入区，等待你发送。

1.2.4 放弃了长按拖入方案，只修复系统分享/打开方式。文档类型从可原地编辑的
`Editor` 改为只读 `Viewer`，并将 `LSSupportsOpeningDocumentsInPlace` 设为
`false`。这样系统“文件”会先把 iCloud 或第三方 File Provider 文件复制到应用自己的
Inbox，程序不再依赖原始提供器 URL 的临时读取权限。收到 URL 后优先直接复制到缓存，
只有其他 App 仍传来受保护 URL 时才使用 `NSFileCoordinator` 兜底。

项目同时在 `UISceneDelegate.scene(_:openURLContexts:)`、冷启动
`connectionOptions.urlContexts`、`UIApplicationDelegate` 启动 URL 和旧式
`application(_:open:options:)` 四个入口汇总文件，避免不同来源只拉起应用却漏掉文件。
长按从系统“文件”拖入不再受支持，请始终使用“分享 → 打开方式 → ChatGPT”。

为避免 iOS 16.3 WebKit 在处理大段 Base64 时占用过多内存，自动注入只处理总计不超过
24 MiB 的文件。程序会主动尝试展开附件控件，并等待网页生成真实的文件输入框。文件
较大、输入框始终没有出现，或 ChatGPT 后续修改了 DOM 时，应用会显示提示并保留
ChatGPT 原生上传流程。

iOS 16 的公开 WebKit API 不能替换网页文件选择器；
`WKOpenPanelParameters` 在 iPhone 上直到 iOS 18.4 才可用。因此回退模式下仍需点击
网页输入框旁的“+”，再从文件原来的位置选择一次。自动注入成功时不需要这一步，文件
会直接出现在输入区。

这个入口使用 iOS 原生 `CFBundleDocumentTypes` 和
`scene(_:openURLContexts:)`，不依赖 Share Extension，因此比 TrollStore 下注册额外
扩展更可靠。覆盖安装后如果“打开方式”里暂时没有 ChatGPT，请在 TrollStore 中执行
**Rebuild Icon Cache** 并 Respring 一次。

## 用 Xcode 构建

1. 打开 `GPTWeb.xcodeproj`。
2. 构建主程序时选择 `GPTWeb` Scheme；保持原 Bundle ID 后可供 TrollStore 覆盖安装。
3. 构建 Safari 扩展时选择 `SafariFixHost` Scheme，在 `SafariFixHost` 和
   `SafariExtension` 两个 Target 中选择同一个 Team，并为两个 Bundle ID 各自生成
   匹配的 Provisioning Profile。
4. 选择真机后运行，或使用 Product → Archive。

## 用 GitHub Actions 生成 IPA

将整个目录提交到 GitHub，打开 Actions，运行 **Build unsigned IPA**。
完成后在该次运行的 Artifacts 中下载 `GPTWeb-unsigned-ipa`，其中同时包含主程序和
Safari 修复器两个未签名 IPA。工作流不需要证书或 Apple 账号。

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

1.2.5 移除了冷启动时恢复最后对话的逻辑。旧版保存的
`GPTWeb.lastFirstPartyURL` 会在升级后清除，但不会清除 WebKit Cookie、登录状态、
站点存储或聊天记录。应用被从多任务划掉后再次打开会加载 ChatGPT 根页面；应用只是
进入后台时不会重置正在查看的对话。

这一版还移除了启动阶段用于“预热”的第二个临时 `WKWebView` 和额外 `URLCache`，
关闭链接长按预览并使用不透明 WebView 以降低合成负担。Work 修复圆点不再用
`MutationObserver` 监听聊天流式输出产生的每一次 DOM 变化，而是在实际触摸、滚动
时重新确认目标。`CADisableMinimumFrameDurationOnPhone` 保持 `true`：按照 Apple
的定义，这只是允许系统在有余量时使用高于默认值的刷新率，并不要求网页持续以
120 Hz 渲染，因此继续交给 ProMotion 动态调节。参见 Apple 的
[`CADisableMinimumFrameDurationOnPhone` 文档](https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone)。

1.2.6 将 `allowsBackForwardNavigationGestures` 关闭，避免系统把左缘右滑解释成网页
后退。主 Frame 中的轻量脚本只记录单指触摸：起点在左侧 36 pt 内、水平位移达到
18 pt 且明显大于纵向位移时，立即触发 ChatGPT 的
`open-sidebar-button`；侧栏已打开时同样阈值的向左滑触发
`close-sidebar-button`。监听器全部使用 `passive: true`，不调用
`preventDefault()`，因此纵向滚动仍由 WebKit 原生处理。

为了缩短点击或滑动后侧栏首次出现的等待，页面空闲时会向打开按钮发送一次
pointer/mouse hover 预热；`#stage-popover-sidebar` 使用 `will-change` 合成提示。
横向意图一旦在 18 pt 被确认就开始打开动画，不等待手指离屏。选择器失效时还会根据
英文/中文无障碍标签寻找左上角菜单按钮，相关语法、方向、阈值、预热和纵向手势共存
由 `scripts/test-sidebar-gesture.js` 做回归检查。

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

本应用的 `WKUserScript` 不能直接修改系统 Safari 中已经打开的网页。iOS 的应用
沙盒把 `WKWebView` 和 Safari 标签页隔离，因此本项目同时提供了独立的
Safari Web Extension，在用户授予网站权限后由 Safari 注入同一套修复逻辑。

在 Safari 中有两种实现方式：

- **推荐：独立 Safari Web Extension 宿主。** iOS 15 起支持 Safari Web
  Extension。本项目已经把同一段修复逻辑作为只匹配 ChatGPT 域名的 content
  script，在页面和子 Frame 加载后自动注入。正常开发者签名安装
  `SafariFixHost` 后，需要在“设置 → Safari → 扩展”中启用，并允许它访问
  `chatgpt.com`。这是长期使用最可靠的方案，也能继续保持 Safari 自己的 Cookie、
  登录状态、下载和标签页功能。
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
