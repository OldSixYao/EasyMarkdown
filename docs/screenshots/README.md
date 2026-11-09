# 应用截图

原有的四张 PNG 由 EasyMarkdown 0.1.8 的实际窗口截取，使用专门的示例文档，不包含私人文件、桌面或其他应用。

- `reading-outline.png`：阅读排版、左侧大纲与当前章节选中。
- `editor-toolbar.png`：源码编辑、Markdown 语法工具栏与未保存提示。
- `split-preview.png`：源码/实时预览分栏和同步滚动入口。
- `dark-reading.png`：深色外观、表格和代码高亮。

新增的 `editor-tabs.png` 展示源码行号及多文档原生标签，同样使用专门的示例文档。

重新截取（需要 macOS 图形会话和窗口截图权限）：

```bash
bash scripts/build-app.sh debug
dist/EasyMarkdown.app/Contents/MacOS/EasyMarkdown --screenshots "$PWD/.build/screenshots"
```

截图入口只在 Debug 构建中启用，只截取该入口创建的示例窗口。检查 `.build/screenshots/` 中的四张图后，将选定图片复制到本目录。该目录不需要保留生成的示例文件。

截图过程使用独立运行实例，暂时调整其显示设置，并在结束前恢复设置。截图期间请避免同时在其他实例修改应用外观设置。
