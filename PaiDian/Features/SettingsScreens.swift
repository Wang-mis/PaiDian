import SwiftUI
import UniformTypeIdentifiers

struct SourcesScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var fileImport = false
    @State private var urlImport = false
    @State private var urlText = ""
    @State private var replacementID: UUID?
    @State private var deleting: SourceScript?
    @State private var notice: String?
    @State private var savingOrder=false
    var body: some View {
        ZStack {
            ScreenBackground()
            NativeSourceList(input:SourceListInput(scripts:model.source.scripts,busy:model.busy,failure:model.source.failure?.userMessage,
                updateMessage:model.source.updateNotice?.message,updateURL:model.source.updateNotice?.url,notice:notice),action:handleAction,save: { order in
                    savingOrder=true;defer { savingOrder=false }
                    return await model.setSourceOrder(order)
                })
            if model.busy { ProgressView(savingOrder ? "正在保存顺序" : "正在初始化音源").padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16)) }
        }.navigationTitle("音源管理").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $fileImport, allowedContentTypes: [.javaScript, .plainText, .data]) { result in switch result { case .success(let url): Task { let before = model.source.revision; await model.importSource(url, replacing: replacementID); if before != model.source.revision { notice = "导入成功，已按列表顺序参与播放回退。" } }; case .failure(let error): model.report(error) } }
            .alert("从 URL 导入", isPresented: $urlImport) { TextField("https://…/source.js", text: $urlText).textInputAutocapitalization(.never).autocorrectionDisabled(); Button("导入") { guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)), ["http","https"].contains(url.scheme ?? ""), url.host != nil else { model.error = "请输入有效的 HTTP 或 HTTPS 地址"; return }; Task { await model.importSource(url, replacing: replacementID) } }; Button("取消", role: .cancel) {} }
            .confirmationDialog("删除“\(deleting?.name ?? "音源")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) { Button("删除音源", role: .destructive) { if let id = deleting?.id { Task { await model.deleteSource(id) } } } }
    }
    private func handleAction(_ action:SourceListAction) {
        switch action {
        case .importFile: replacementID=nil;fileImport=true
        case .importURL: replacementID=nil;urlText="";urlImport=true
        case .replaceFile(let id):replacementID=id;fileImport=true
        case .replaceURL(let id):replacementID=id;urlText=model.source.scripts.first { $0.id == id }?.originURL?.absoluteString ?? "";urlImport=true
        case .delete(let id):deleting=model.source.scripts.first { $0.id == id }
        case .retry(let id):Task { await model.activateSource(id) }
        case .error(let message):model.error=message
        case .retryAll:Task { await model.sourceManager?.restoreActive() }
        case .openUpdate(let url):openURL(url)
        }
    }

}
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var cacheSize = 0
    @State private var audioCacheSize:Int64=0
    @State private var clearing = false
    var body: some View { @Bindable var model = model
        Form {
            Section { NavigationLink("音源管理", value: AppRoute.sources) }
            Section {
                Picker("外观",selection:$model.settings.appearance) { ForEach(Appearance.allCases,id:\.self) { Text($0.name).tag($0) } }
                Picker("最高音质",selection:$model.settings.qualityRange.maximum) {
                    ForEach(AudioQuality.allCases.filter{$0.rank >= model.settings.qualityRange.minimum.rank}) { quality in Text("\(quality.name) · \(quality.rawValue)").tag(quality) }
                }.accessibilityIdentifier("maximumQuality")
                Picker("最低音质",selection:$model.settings.qualityRange.minimum) {
                    ForEach(AudioQuality.allCases.filter{$0.rank <= model.settings.qualityRange.maximum.rank}) { quality in Text("\(quality.name) · \(quality.rawValue)").tag(quality) }
                }.accessibilityIdentifier("minimumQuality")
            } header: { Text("播放与显示") } footer: { Text("按音源列表顺序，在每个音源内由最高到最低尝试。修改用于下一首、重新选曲或手动重试，不中断当前播放。") }
            Section("歌词显示") {
                Stepper("字号 · \(Int(model.settings.lyricFontSize)) pt",value:$model.settings.lyricFontSize,in:14...24,step:1)
                Stepper("行间距 · \(Int(model.settings.lyricLineSpacing)) pt",value:$model.settings.lyricLineSpacing,in:6...28,step:2)
                Stepper("当前行放大 · \(Int((model.settings.lyricCurrentLineScale*100).rounded()))%",value:$model.settings.lyricCurrentLineScale,in:1...1.25,step:0.01)
                VStack(spacing:model.settings.lyricLineSpacing) {
                    Text("上一句歌词").foregroundStyle(.secondary)
                    Text("正在播放的歌词").scaleEffect(model.settings.lyricCurrentLineScale).foregroundStyle(Theme.red)
                    Text("下一句歌词").foregroundStyle(.secondary)
                }.font(.system(size:model.settings.lyricFontSize)).frame(maxWidth:.infinity).padding(.vertical,16).accessibilityLabel("歌词显示预览")
                Button("恢复歌词显示默认值") { model.settings.lyricFontSize=17;model.settings.lyricLineSpacing=14;model.settings.lyricCurrentLineScale=1.08 }
            }
            Section { HStack { Text("图片与歌词缓存"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)).foregroundStyle(.secondary) }; Button("清除缓存") { Task { clearing = true; do { try await model.cache?.clear(); cacheSize = 0 } catch { model.report(error) }; clearing = false } }.disabled(clearing) }
            Section {
                Picker("音频缓存上限",selection:$model.settings.audioCacheGB) { ForEach([1,2,5],id:\.self) { Text("\($0) GB").tag($0) } }
                LabeledContent("音频缓存",value:ByteCountFormatter.string(fromByteCount:audioCacheSize,countStyle:.file))
                Button("清除音频缓存") { Task { do { try await model.audioCache?.clear();audioCacheSize=(try? await model.audioCache?.size()) ?? 0 } catch { model.report(error) } } }
            } header: { Text("音频缓存") } footer: { Text("自动缓存当前歌曲。正在播放的文件会保留至播放结束；歌单、音源和歌词调整不会删除。") }
            Section("关于") { LabeledContent("拍点", value: Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—"); Text("个人音乐播放器 · iOS 17+\n歌曲来自你选择的平台与音源，歌单保存在本机。").font(.footnote).foregroundStyle(.secondary) }
            #if DEBUG
            Section("开发") { NavigationLink("集成诊断") { DiagnosticsScreen() } }
            #endif
        }.navigationTitle("设置").onChange(of: model.settings) { _, _ in Task { await model.saveSettings() } }.task { cacheSize = (try? await model.cache?.size()) ?? 0;audioCacheSize=(try? await model.audioCache?.size()) ?? 0 }
    }
}
#if DEBUG
struct DiagnosticsScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View { List { Section("运行状态") { LabeledContent("源 API", value: "2.0.0 / mobile"); LabeledContent("已导入音源", value: "\(model.source.scripts.count)"); LabeledContent("活动实例", value: model.source.generation.uuidString); LabeledContent("支持平台", value: model.source.capabilities.platforms.keys.map(\.name).sorted().joined(separator: " / ")); LabeledContent("播放状态", value: model.playback.status.rawValue); LabeledContent("队列", value: "\(model.playback.queue.entries.count)") }; Section { NavigationLink("导入与初始化音源", value: AppRoute.sources); NavigationLink("搜索与播放闭环", value: AppRoute.search); Button("打开播放队列") { model.showQueue = true }; Button("保存播放快照") { model.pauseAndSave() } }; Section { Text("此页读取真实服务状态，不注入在线示例曲目。真实脚本和真机兼容性以开发记录为准。").font(.footnote) } }.playbackInset().navigationTitle("集成诊断") }
}
#endif
