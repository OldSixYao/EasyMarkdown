# 开发与使用说明

本文中的命令均从仓库根目录执行。版本更新见 [CHANGELOG](../CHANGELOG.md)，界面截图见[项目首页](../README.md)。

最低支持 macOS 14，使用 SwiftUI、AppKit `NSTextView` 和 `WKWebView`。当前为本机开发预览版，尚未完成开发者签名、公证或 App Store 分发。

## 构建与运行

需要 macOS 和 Swift 5.9 或更新的工具链。可以使用 Xcode，也可以使用 Command Line Tools。

```bash
bash scripts/build-app.sh
open dist/EasyMarkdown.app
```

打开示例：

```bash
open -a "$PWD/dist/EasyMarkdown.app" "$PWD/Examples/欢迎使用.md"
```

也可以直接运行 `swift run EasyMarkdown /绝对路径/文档.md`。需要生成带文件关联元数据的应用包时，请使用构建脚本。

构建脚本进行本机 ad-hoc 签名，不会安装应用、修改系统默认打开方式或访问发布服务。Intel Mac 应在对应机器上构建；当前没有提供通用二进制安装包。

## 常用操作

通过菜单“EasyMarkdown → 关于 EasyMarkdown”可以查看应用图标、当前版本与构建号，并点击 GitHub 仓库链接访问项目。

| 操作 | 快捷键或入口 |
| --- | --- |
| 打开 | `⌘O`，或拖入文件 |
| 保存 | `⌘S` |
| 另存为 | `⇧⌘S` |
| 编辑 / 保存并完成 | `⌘E` |
| 查找 | `⌘F` |
| 阅读中查找下一个 | `⌘G` |
| 替换 | 编辑器原生查找栏中展开替换选项 |
| 设置 | `⌘,` |

点击“完成”会保存并返回阅读视图；保存失败时保留编辑模式和内容。

编辑后顶部常驻橙色“未保存”标记，支持点击“保存”继续编辑，或按 `⌘S`。保存过程中显示“正在保存…”，成功后显示“已保存”；失败后保留红色“保存失败 · 未保存”提示。恢复草稿不会清除原文件未保存状态。

发生外部冲突后，可以查看磁盘版本、确认加载外部版本，或将本地内容另存为。继续编辑不会自动覆盖外部文件。首版没有自动合并或强制覆盖按钮。

Markdown 工具栏只在源码编辑和分栏模式显示。选中文字后点击粗体、斜体等按钮可包裹选区，再次使用可移除对应标记；标题、引用和列表按所在行或选中的多行处理。没有选区时插入可直接替换的占位内容，链接/图片会选中待填写的地址，所有操作使用编辑器原生撤销。

鼠标移到顶部工具栏按钮时，按钮显示强调色背景和边框；停留片刻会出现系统名称提示。标题和“更多”菜单也支持这一效果，禁用按钮不显示悬停高亮。

分栏视图中，滚动源码或预览都会带动另一侧。顶部蓝色链条图标表示同步开启，点击后可以独立滚动，再次开启时按源码当前阅读位置对齐。

应用使用蓝色圆角底、白色折角文档和 Markdown 标记的专用图标，已配置 Finder/Dock 图标和运行时应用图标。图标源绘制脚本为 `scripts/generate-icon.swift`，执行 `swift scripts/generate-icon.swift` 可重新生成 `Assets/AppIcon.png` 和 `Assets/AppIcon.icns`，构建时自动打包。

## 验证

不依赖 XCTest 的核心回归检查：

```bash
bash scripts/check-core.sh
```

实际应用窗口与 WebKit 检查（需要已登录的 macOS 图形会话，会短暂打开测试窗口）：

```bash
bash scripts/check-app.sh
```

第二条命令构建 Debug 应用并进行 Markdown 渲染、原子替换刷新、段落位置保持、分栏预览、本地编辑冲突、另存为、HTML 过滤、图片加载、删除和草稿恢复检查。结果与阅读预览截图位于 `.build/smoke/`。测试完成后，可以重新运行 `bash scripts/build-app.sh` 生成 Release 应用。

安装完整 Xcode 后，也可使用 `swift test` 运行 `Tests/EasyMarkdownCoreTests` 中相同的 25 个核心测试。仅安装 Command Line Tools 的环境可能不提供 XCTest。

性能优化记录与复测方法见 [PERFORMANCE.md](PERFORMANCE.md)。详细验证记录见 [VALIDATION.md](../VALIDATION.md)。

## 当前限制

- “同步”只覆盖已写入本机文件系统的变化；其他编辑器未保存的内容、云服务尚未下载的内容不可见。
- 当前支持 UTF-8、带 BOM 的 UTF-8/UTF-16，并尽量保留原编码及一致的 CRLF 换行；其他编码和二进制文件明确拒绝读取。
- 首版文件上限为 24 MB；超过 500,000 个字符时预览降级为截断的纯文本，编辑器仍显示全文。长文本基础高亮有单独的大小限制。
- 本地图片访问限制在文档目录内，暂不加载 `../` 指向目录外的图片。当前应用未启用 App Sandbox，商店分发所需的目录授权流程尚未实现。
- 单张本地图片文件上限为 128 MB，不自动缩小原图；远程图片及动画的实际解码内存仍由 WebKit 管理。
- XML 格式化拒绝 DTD 和实体声明，不承诺保留所有排版细节；JSON 格式化使用 Foundation 的数据模型。
- 首版不提供新建文档、富文本式 Markdown 编辑、文件夹工作区、插件、PDF 导出或自动冲突合并。
- 滚动保持采用内容锚点的尽力恢复；段落被删除、重复内容变化、复杂布局变化时可能退回相对位置。
- 中文输入法的实际交互、关闭/退出对话框、系统文件关联和不同 macOS 版本仍需要人工回归。当前机器上的自动检查不等于 macOS 14 实机兼容性验证。

## 结构

```text
Sources/EasyMarkdownCore/  文件快照、冲突状态、协调读写、格式化
Sources/EasyMarkdown/      原生窗口、文档生命周期、编辑器、WebKit 预览和恢复草稿
Sources/EasyMarkdown/Resources/  离线渲染脚本与阅读样式
Tests/                    核心回归测试
scripts/                  构建和验证入口
Examples/                 可直接打开的示例
PLAN.md                   初版产品方案
```

第三方资源：marked 15.0.12、DOMPurify 3.3.0、highlight.js 11.11.1。对应许可随资源一同打包。
