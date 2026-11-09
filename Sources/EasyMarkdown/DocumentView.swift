import EasyMarkdownCore
import SwiftUI
import UniformTypeIdentifiers

struct DocumentView: View {
    @Bindable var session: DocumentSession
    @AppStorage("appearance") private var appearance = "system"
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if session.kind == .markdown && session.mode != .read {
                MarkdownToolbar(session: session)
                Divider()
            }
            if session.recovery != nil { recoveryBanner }
            if session.state.hasConflict { conflictBanner }
            if session.showFind && session.mode == .read { findBar }
            HStack(spacing: 0) {
                if session.showOutline && session.kind == .markdown {
                    outline.frame(width: 210)
                    Divider()
                }
                // Keep the visible pane's identity when adding/removing its neighbor.
                HSplitView {
                    if session.mode != .read || session.usesNativeReader {
                        SourceEditor(session: session, isReadOnly: session.mode == .read).frame(minWidth: 240)
                    }
                    if session.mode != .edit {
                        if session.usesNativeReader {
                            if session.mode == .split {
                                SourceEditor(session: session, isReadOnly: true, isSecondary: true).frame(minWidth: 240)
                            }
                        } else {
                            ZStack(alignment: .top) {
                                if let snapshot = session.previewActivity.snapshot {
                                    Image(nsImage: snapshot).resizable().scaledToFit()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                        .accessibilityHidden(true)
                                }
                                if session.previewActivity.isAwake {
                                    MarkdownPreview(session: session)
                                        .opacity(session.previewActivity.snapshot == nil ? 1 : 0)
                                }
                            }.frame(minWidth: 240)
                        }
                    }
                }
            }
            EditorStatusBar(session: session)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        .alert(L10n.text("无法完成操作"), isPresented: Binding(get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } })) {
                Button(L10n.text("好"), role: .cancel) { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
        .sheet(isPresented: $session.showExternal) {
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.text("磁盘上的最新版本")).font(.headline)
                    Spacer()
                    Button(L10n.text("关闭")) { session.showExternal = false }.keyboardShortcut(.cancelAction)
                }.padding()
                Divider()
                if session.usesNativeReader {
                    SourceEditor(session: session, isReadOnly: true,
                        overrideText: session.state.external?.text ?? session.state.baseline.text)
                } else {
                    MarkdownPreview(session: session, overrideText: session.state.external?.text ?? session.state.baseline.text)
                }
            }.frame(width: 760, height: 600)
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: acceptDrop)
        .onChange(of: session.showFind) { _, visible in searchFocused = visible }
        .onChange(of: session.state.revision, initial: true) { _, _ in session.refreshReadingStatistics() }
        .onChange(of: session.mode) { _, _ in session.refreshReadingStatistics() }
        .onAppear { DispatchQueue.main.async { session.updateWindowActivity() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { event in
            if let window = event.object as? NSWindow,
               session.document?.windowControllers.contains(where: { $0.window === window }) == true {
                session.setWindowActive(true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { event in
            if let window = event.object as? NSWindow,
               session.document?.windowControllers.contains(where: { $0.window === window }) == true {
                session.setWindowActive(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { event in
            if let window = event.object as? NSWindow,
               session.document?.windowControllers.contains(where: { $0.window === window }) == true {
                session.setWindowActive(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.setWindowActive(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.updateWindowActivity()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if session.kind == .markdown {
                Button { session.showOutline.toggle() } label: {
                    Image(systemName: "sidebar.left").frame(width: 26, height: 26)
                }
                    .toolbarHoverFeedback(L10n.text("大纲：显示或隐藏文档标题"))
            }
            if session.mode != .read || session.state.isDirty || session.isSaving {
                saveStateBadge
            } else if !session.status.isEmpty {
                Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if session.mode != .read {
                Picker(L10n.text("视图"), selection: $session.mode) {
                    Text(L10n.text("源码")).tag(ViewMode.edit)
                    Text(L10n.text("分栏")).tag(ViewMode.split)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 128)
                    .accessibilityLabel(L10n.text("视图"))
                    .help(L10n.text("视图：切换源码编辑或分栏预览"))
                if session.mode == .split {
                    Button {
                        session.synchronizeSplitScroll.toggle()
                        if session.synchronizeSplitScroll { session.alignPreviewToEditor?() }
                    } label: {
                        Image(systemName: "link")
                            .frame(width: 26, height: 26)
                            .foregroundStyle(session.synchronizeSplitScroll ? Color.accentColor : Color.secondary)
                    }
                    .toolbarHoverFeedback(session.synchronizeSplitScroll ? L10n.text("同步滚动已开启，点击关闭") : L10n.text("同步滚动已关闭，点击开启"))
                    .accessibilityValue(session.synchronizeSplitScroll ? L10n.text("开启") : L10n.text("关闭"))
                }
                if session.kind == .json || session.kind == .xml {
                    Button(L10n.text("格式化")) { session.format() }.disabled(session.isSaving || session.isFormatting)
                        .toolbarHoverFeedback(L10n.text("格式化文档"))
                    if session.isFormatting { ProgressView().controlSize(.small) }
                }
            }
            Button {
                if session.mode == .read && session.showFind { session.closeSearch() }
                else { session.showSearch() }
            } label: { Image(systemName: "magnifyingglass").frame(width: 26, height: 26) }
                .toolbarHoverFeedback(L10n.text("查找 ⌘F"))
            if session.mode == .read {
                Button { session.mode = .edit } label: { Label(L10n.text("编辑"), systemImage: "square.and.pencil") }
                    .toolbarHoverFeedback(L10n.text("编辑文档 ⌘E"))
            } else {
                Button(L10n.text("保存")) { session.save() }
                    .fixedSize()
                    .buttonStyle(.bordered)
                    .disabled(!session.state.isDirty || session.isSaving)
                    .toolbarHoverFeedback(L10n.text("保存文档 ⌘S"))
                Button(L10n.text("完成")) { session.save(finishing: true) }.disabled(session.isSaving)
                    .fixedSize()
                    .buttonStyle(.borderedProminent)
                    .toolbarHoverFeedback(L10n.text("完成：保存并返回阅读 ⌘E"))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20).frame(height: 46)
        .background(.bar)
    }

    private var saveStateBadge: some View {
        let dirty = session.state.isDirty
        let failed = dirty && session.saveFailure != nil
        let tint: Color = failed ? .red : dirty ? Color(nsColor: .systemOrange) : .secondary
        return HStack(spacing: 5) {
            if session.isSaving {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: failed ? "exclamationmark.circle.fill" : dirty ? "circle.fill" : "checkmark.circle")
                    .font(.system(size: dirty && !failed ? 7 : 12))
            }
            Text(session.saveStateLabel).font(.system(size: 12, weight: dirty ? .semibold : .regular))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(tint.opacity(dirty ? 0.14 : 0.06), in: Capsule())
        .fixedSize()
        .help(dirty ? (session.saveFailure ?? L10n.text("修改尚未写入文件，按 ⌘S 保存。恢复草稿不代表原文件已保存。")) : L10n.text("当前内容已保存到文件"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.saveStateLabel)
        .accessibilityIdentifier("documentSaveState")
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("文档大纲")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 20)
            if session.headings.isEmpty {
                Text(L10n.text("暂无标题")).font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 16)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(session.headings) { heading in
                            let selected = session.activeHeadingID == heading.id
                            Button {
                                if session.mode == .edit { session.mode = .split }
                                session.activeHeadingID = heading.id
                                session.scrollTarget = heading.id
                                session.scrollRequest += 1
                            } label: {
                                Text(heading.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.accentColor : Color.primary).lineLimit(2)
                                    .padding(.vertical, 8).padding(.leading, CGFloat(min(heading.level - 1, 3) * 10 + 16))
                                    .padding(.trailing, 12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected ? Color.accentColor.opacity(0.13) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(alignment: .leading) {
                                        if selected {
                                            Capsule().fill(Color.accentColor).frame(width: 3, height: 16).padding(.leading, 5)
                                        }
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityValue(selected ? L10n.text("当前阅读位置") : "")
                            .id(heading.id)
                        }
                    }.padding(.horizontal, 8)
                }
                .onAppear {
                    if let id = session.activeHeadingID { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: session.activeHeadingID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.text("在文档中查找"), text: $session.search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("reader-search")
                .frame(minWidth: 80)
                .layoutPriority(1)
                .onSubmit { session.navigateSearch() }
            if !session.search.isEmpty {
                Text(session.searchResultCount.map {
                    session.searchIsTruncated ? L10n.format("当前预览共 %d 处", $0) : L10n.format("共 %d 处", $0)
                } ?? L10n.text("查找中…"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize()
                    .accessibilityIdentifier("reader-search-count")
            }
            Button(L10n.text("上一个")) { session.navigateSearch(backwards: true) }
                .fixedSize()
                .disabled(session.search.isEmpty || session.searchResultCount == 0)
                .help(L10n.text("查找上一个 ⇧⌘G"))
            Button(L10n.text("下一个")) { session.navigateSearch() }
                .fixedSize()
                .disabled(session.search.isEmpty || session.searchResultCount == 0)
                .help(L10n.text("查找下一个 ⌘G"))
            Button(L10n.text("替换…")) { session.showReplace() }
                .fixedSize()
                .disabled(session.isSaving)
                .help(L10n.text("在源码编辑器中查找并替换 ⌥⌘F"))
            Button { session.closeSearch() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel(L10n.text("关闭查找"))
        }.padding(.horizontal, 20).padding(.vertical, 9).background(.bar)
    }

    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(session.state.isMissing ? L10n.text("原文件已移动或删除，当前内容已保留。") : L10n.text("文件已在其他位置修改，本地编辑已保留。"))
                .font(.callout)
            Spacer(minLength: 0)
            if session.state.external != nil {
                Button(L10n.text("查看外部版本")) { session.showExternal = true }
                Button(L10n.text("加载外部版本")) { session.acceptExternal() }
            }
            Button(L10n.text("另存为…")) { session.saveAs() }
        }.padding(12).background(.orange.opacity(0.09))
    }

    private var recoveryBanner: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
            Text(L10n.text("发现上次未保存的恢复草稿。")).font(.callout)
            Spacer()
            Button(L10n.text("恢复")) { session.restoreDraft() }
            Button(L10n.text("忽略")) { session.discardRecovery() }
        }.padding(12).background(.blue.opacity(0.08))
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in (NSApp.delegate as? AppDelegate)?.open(url) }
            }
        }
        return !providers.isEmpty
    }
}
