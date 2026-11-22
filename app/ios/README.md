# iOS APP

构建与运行方式见 [贡献文档](../../docs/contributing/README.md)。

## 原生界面调试

最低部署版本为 iOS/iPadOS 26，SwiftUI 界面的构建需要 iOS 26 或更高版本的 SDK。使用 Apple Silicon Mac，在 [贡献文档](../../docs/contributing/running.md#如何运行-ios-app) 配置 Kotlin framework，然后安装 Pods、构建模拟器版本并打开 `Animeko.xcworkspace`。

```shell
./gradlew :app:ios:podInstall
./gradlew :app:ios:buildDebugForSimulator
```

`AnimekoNativeUI` scheme 以 `-AnimekoNativeUI` 启动 SwiftUI 界面。设置中的「打开完整应用」进入常规界面。正式构建使用 `Animeko` scheme。

账号菜单提供通知、观看记录和 Bangumi 收藏冲突处理入口。通知、公告、已读状态、观看记录和合并选择与常规界面共用 Kotlin 数据层。

设置中的外观、搜索与播放偏好写入共享设置仓库。数据源设置可管理订阅与本地数据源，订阅刷新和导出使用现有订阅格式。

在「数据源」的操作菜单添加 CSS Selector、JSON API 或 RSS 配置。长按已有数据源可进入配置页。表单处理常用参数，「高级 JSON 配置」包含完整参数，导入和导出使用现有数据源格式。连接和搜索测试使用当前草稿，保存前不会修改数据源列表。

播放来源页支持手动查找与记住剧集选择。剧集、人物和角色的评论入口打开各自的评论列表和回复线程。

条目详情和下载列表提供条目下载入口。添加下载使用共享选源会话，支持下载单集和从同一线路批量下载。

播放器内的选集保持当前条目的播放会话。「音频与视频」提供播放器音量、画面适配和超分选项，具体选项取决于播放器能力。

在 scheme 中选择已安装的 iPhone 模拟器运行 UI 测试，也可把模拟器的 UDID 传给 Gradle。

```shell
./gradlew :app:ios:testNativeInterface '-Pani.ios.simulator.destination=platform=iOS Simulator,id=<UDID>'
```

## 分层应用图标

`IconComposer/` 下的图标源文件提供 1024 × 1024 画布上的蓝色外圈、白色内圆和「あ」字标。Icon Composer 的背景填充使用 `#2F3943`，图层按文件编号从底到顶排列。Xcode 使用 `.icon` 文件生成各外观和尺寸的图标。[Apple Icon Composer 文档](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer)

## 未捕获异常

Kotlin/Native 的异常钩子在处理异常时获取当前日志 writer，将原始异常与堆栈写入文件并 flush，然后委托给先前的钩子或终止进程。

`pod install` 通过 `scripts/sentry_terminate_patch.rb` 修补 Sentry Cocoa 的 C++ terminate 回调：进入回调时保存前任 handler，在 Sentry 完成崩溃记录后调用它。Sentry 的 fatal-event cleanup 会禁用 monitor 并清空全局 handler，局部快照保证 Kotlin/Native 异常钩子仍能执行。补丁保留 Sentry 的原生崩溃捕获，不改变依赖版本；升级 Sentry 时需要检查此补丁，无法识别的函数结构会使安装失败。

原生回调回归测试与日志写入、钩子委托测试（`IosUnhandledExceptionHookTest`）都在 PR 的 macOS CI 中运行，本地运行方式：

```shell
./gradlew :app:ios:testSentryTerminatePatch
./gradlew :app:shared:application:iosSimulatorArm64Test
```

真实崩溃链需要在未附加调试器的 iOS 进程中验证，因为 Sentry 会根据调试器状态调整原生 monitor。
