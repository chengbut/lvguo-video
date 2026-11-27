import SwiftUI

// MARK: - 弹幕偏好

/// 弹幕偏好：字段、默认值与取值范围与 Flutter
/// PlaybackPreferences 的 danmaku 一组逐项一致，落盘
/// danmaku.json（键名同 Flutter 的 JSON 名），首次启动从
/// 旧版用户设置的 playback 子对象种子。
@MainActor
final class DanmakuPreferencesStore: ObservableObject {
@Published var enabled: Bool { didSet { save()}}
@Published var scale: Double { didSet { save()}}
@Published var colorValue: Int { didSet { save()}}
@Published var opacity: Double { didSet { save()}}
@Published var bold: Bool { didSet { save()}}
@Published var stroke: Double { didSet { save()}}
@Published var shadow: Double { didSet { save()}}
@Published var coverage: String { didSet { save()}}
@Published var speed: Double { didSet { save()}}
@Published var merge: String { didSet { save()}}
@Published var words: [String] { didSet { save()}}

private let file: URL
private var loading = true

static let colors: [Int] = [
0xFFFF_FFFF, 0xFFFF_E066, 0xFF66_E0FF, 0xFFFF_8FB8, 0xFF8C_F08C,
]
static let colorLabels = ["白色", "黄色", "青色", "粉色", "绿色"]
static let coverages: [(String, String, Double)] = [
("quarter", "顶部四分之一", 0.25),
("half", "顶部一半", 0.5),
("full", "全部", 1.0),
]
static let merges: [(String, String, Int)] = [
("off", "关闭", 0), ("ten", "10 秒", 10),
("twenty", "20 秒", 20), ("thirty", "30 秒", 30),
]

init(dataDirectory: URL) {
file = dataDirectory.appendingPathComponent("danmaku.json")
var dict = AppData.readJSONDictionary(file)
if dict == nil,
let user = LegacySettingsSeed.userSettings(),
let playback = user["playback"] as? [String: Any] {
dict = playback
}
let source = dict ?? [:]
enabled = source["danmaku"] == nil
? true: JSON.dictBool(source["danmaku"])
scale = Self.clamp(
Self.double(source["danmakuScale"], fallback: 1), 0.6...2.0
)
colorValue = (source["danmakuColor"] as? NSNumber)?.intValue
?? 0xFFFF_FFFF
opacity = Self.clamp(
Self.double(source["danmakuOpacity"], fallback: 1), 0.1...1.0
)
bold = source["danmakuBold"] == nil
? true: JSON.dictBool(source["danmakuBold"])
stroke = Self.clamp(
Self.double(source["danmakuStroke"], fallback: 0), 0...6
)
shadow = Self.clamp(
Self.double(source["danmakuShadow"], fallback: 3), 0...12
)
let storedCoverage = JSON.dictString(source["danmakuCoverage"])
coverage = Self.coverages.contains { $0.0 == storedCoverage}
? storedCoverage: "half"
speed = Self.clamp(
Self.double(source["danmakuSpeed"], fallback: 1), 0.5...2.0
)
let storedMerge = JSON.dictString(source["danmakuMerge"])
merge = Self.merges.contains { $0.0 == storedMerge}
? storedMerge: "ten"
words = (source["danmakuWords"] as? [Any]) ?? []
.compactMap { $0 as? String}
loading = false
if AppData.readJSONDictionary(file) == nil, dict!= nil {
save()
}
}

var coverageFraction: Double {
Self.coverages.first { $0.0 == coverage}?.2 ?? 0.5
}

var mergeSeconds: Int {
Self.merges.first { $0.0 == merge}?.2 ?? 10
}

var color: Color {
Color(argb: UInt32(bitPattern: Int32(truncatingIfNeeded: colorValue)))
}

private static func double(_ value: Any?, fallback: Double) -> Double {
(value as? NSNumber)?.doubleValue ?? fallback
}

private static func clamp(
_ value: Double, _ range: ClosedRange<Double>
) -> Double {
min(max(value, range.lowerBound), range.upperBound)
}

private func save() {
guard !loading else { return }
AppData.writeJSON([
"danmaku": enabled,
"danmakuScale": scale,
"danmakuColor": colorValue,
"danmakuOpacity": opacity,
"danmakuBold": bold,
"danmakuStroke": stroke,
"danmakuShadow": shadow,
"danmakuCoverage": coverage,
"danmakuSpeed": speed,
"danmakuMerge": merge,
"danmakuWords": words,
], to: file)
}
}

extension Color {
init(argb value: UInt32) {
self.init(
red: Double((value >> 16) & 0xFF) / 255,
green: Double((value >> 8) & 0xFF) / 255,
blue: Double(value & 0xFF) / 255,
opacity: Double((value >> 24) & 0xFF) / 255
)
}
}

/// 屏蔽词匹配用的归一化，对齐 Flutter normalizedSearchText：
/// 全角转半角、转小写、去掉空白与常见标点。
func normalizedDanmakuText(_ text: String) -> String {
var result = ""
for scalar in text.unicodeScalars {
var value = scalar.value
if value >= 0xFF01 && value <= 0xFF5E {
value -= 0xFEE0
}
if let converted = UnicodeScalar(value) {
result.unicodeScalars.append(converted)
}
}
let stripped = result.lowercased().unicodeScalars.filter { scalar in
if scalar.properties.isWhitespace { return false}
return !"，。！？、：；·「」『』（）《》“”‘’.,!?:;-_/()[]{}".unicodeScalars
.contains(scalar)
}
return String(String.UnicodeScalarView(stripped))
}

// MARK: - 弹幕数据

struct DanmakuItem: Identifiable {
var id: String
var text: String
var timeMS: Int64
var count: Int = 1

var displayText: String {
count > 1? "\(text) ×\(count)": text
}
}

struct DanmakuPage {
var items: [DanmakuItem] = []
var nextMS: Int64 = 0
var total: Int64 = 0
}

/// 一集弹幕的加载与预处理：屏蔽词过滤 + 重复合并，
/// 规则对齐 Flutter DanmakuController。
@MainActor
final class DanmakuController: ObservableObject {
@Published private(set) var items: [DanmakuItem] = []
@Published private(set) var loaded = false
private var rawItems: [DanmakuItem] = []

private var loadTask: Task<Void, Never>?

func load(
provider: ModuleProvider, task: [String: Any],
preferences: DanmakuPreferencesStore
) {
loadTask?.cancel()
items = []
loaded = false
loadTask = Task { [weak self] in
guard let self else { return}
guard let ids = await provider.danmakuIDs(task: task) else {
self.loaded = true
return
}
var collected: [DanmakuItem] = []
var startMS: Int64 = 0
for _ in 0..<40 {
if Task.isCancelled { return}
guard let page = try? await provider.danmaku(
series: ids.series, video: ids.video,
startMS: startMS, durationMS: 10 * 60 * 1000
) else { break}
collected.append(contentsOf: page.items)
if page.nextMS <= startMS || page.items.isEmpty { break}
startMS = page.nextMS
if page.total > 0 && collected.count >= page.total { break}
}
self.rawItems = collected
self.items = Self.process(
collected, preferences: preferences
)
self.loaded = true
}
}

func reset() {
loadTask?.cancel()
items = []
rawItems = []
loaded = false
}

/// 屏蔽词/合并窗口改动后按新偏好重跑过滤与合并（不重新取数据）
func reprocess(preferences: DanmakuPreferencesStore) {
guard loaded else { return}
items = Self.process(rawItems, preferences: preferences)
}

/// 屏蔽词过滤（归一化后包含匹配）+ 时间窗内同文合并计数，
/// 与 Flutter _mergeItems 的口径一致。
static func process(
_ source: [DanmakuItem], preferences: DanmakuPreferencesStore
) -> [DanmakuItem] {
let blocked = preferences.words
.map(normalizedDanmakuText)
.filter {!$0.isEmpty}
let kept = source
.filter { item in
if blocked.isEmpty { return true}
let text = normalizedDanmakuText(item.text)
return !blocked.contains { text.contains($0) }
}
.sorted { $0.timeMS < $1.timeMS}
let window = preferences.mergeSeconds * 1000
guard window > 0 else { return kept}
var merged: [DanmakuItem] = []
var slots: [String: Int] = [:]
for item in kept {
if let slot = slots[item.text],
item.timeMS - merged[slot].timeMS <= Int64(window) {
merged[slot].count += 1
} else {
slots[item.text] = merged.count
merged.append(item)
}
}
return merged
}
}

// MARK: - 弹幕渲染层

/// 弹幕滚动渲染：条目在各自 timeMS 出生、从右向左划过，
/// 轨道数由显示区域（coverage）决定，速度/字号/颜色/
/// 透明度/加粗/描边/阴影全部读 DanmakuPreferencesStore，
/// 设置改动即时作用于正在显示的弹幕。
struct DanmakuOverlay: View {
@ObservedObject var engine: PlaybackEngine
@ObservedObject var controller: DanmakuController
@EnvironmentObject private var preferences: DanmakuPreferencesStore

/// 时间插值基准：引擎 currentTime 是低频发布，本地按
/// 播放状态与倍速在两次发布之间插值出平滑时间。
@State private var baseTime: Double = 0
@State private var baseStamp = Date()
@State private var basePlaying = false
@State private var baseRate: Double = 1

private static let baseTravel: Double = 9 // 秒（速度 1x 时划过全屏）

var body: some View {
GeometryReader { proxy in
if preferences.enabled,!controller.items.isEmpty {
TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
ZStack(alignment:.topLeading) {
ForEach(
visibleItems(
at: displayTime(now: context.date),
size: proxy.size
),
id: \.index
) { entry in
danmakuText(entry.item)
.position(x: entry.x, y: entry.y)
}
}
}
}
}
.allowsHitTesting(false)
.onChange(of: engine.currentTime) { _, value in
syncBase(time: value)
}
.onChange(of: engine.isPlaying) { _, _ in
syncBase(time: engine.currentTime)
}
.onAppear { syncBase(time: engine.currentTime)}
}

private func syncBase(time: Double) {
baseTime = time
baseStamp = Date()
basePlaying = engine.isPlaying
baseRate = Double(engine.playbackRate)
}

private func displayTime(now: Date) -> Double {
guard basePlaying else { return baseTime}
return baseTime + now.timeIntervalSince(baseStamp) * baseRate
}

private func danmakuText(_ item: DanmakuItem) -> some View {
let fontSize = 16 * preferences.scale
let text = Text(item.displayText)
.font(
.system(
size: fontSize,
weight: preferences.bold?.bold:.regular
)
)
.foregroundStyle(preferences.color)
.opacity(preferences.opacity)
.lineLimit(1)
.fixedSize()
return ZStack {
if preferences.stroke > 0 {
let offset = preferences.stroke * 0.3
ForEach(0..<4, id: \.self) { corner in
text
.foregroundStyle(.black)
.offset(
x: [offset, -offset, offset, -offset][corner],
y: [offset, offset, -offset, -offset][corner]
)
}
}
text
.shadow(
color:.black.opacity(preferences.shadow > 0? 0.55: 0),
radius: preferences.shadow / 2,
x: 1, y: 1
)
}
}

private struct VisibleEntry {
var index: Int
var item: DanmakuItem
var x: Double
var y: Double
}

private func visibleItems(
at time: Double, size: CGSize
) -> [VisibleEntry] {
let travel = Self.baseTravel / preferences.speed
let nowMS = time * 1000
let laneHeight = 16 * preferences.scale + 10
let laneCount = max(
1, Int(size.height * preferences.coverageFraction / laneHeight)
)
// 轨道分配：按出生顺序贪心放进「上一条已离开安全间隔」的轨道
var laneFreeAt: [Double] = Array(
repeating: -Double.greatestFiniteMagnitude, count: laneCount
)
var entries: [VisibleEntry] = []
for (index, item) in controller.items.enumerated() {
let age = (nowMS - Double(item.timeMS)) / 1000
let born = age >= -travel - 1 && age <= travel
let textWidth = Double(item.displayText.count)
* 16 * preferences.scale * 0.98 + 8
// 先推进轨道占用（与是否可见无关，保证分配稳定）
var lane = -1
for candidate in 0..<laneCount
where Double(item.timeMS) >= laneFreeAt[candidate] {
lane = candidate
break
}
if lane < 0 { lane = (item.id.hashValue % laneCount + laneCount) % laneCount}
let spacing = (textWidth / (size.width + textWidth)) * travel
laneFreeAt[lane] = Double(item.timeMS) + (spacing + 0.4) * 1000
guard born, age >= 0 else { continue}
let progress = age / travel
let x = size.width + textWidth / 2
- progress * (size.width + textWidth)
let y = laneHeight * (Double(lane) + 0.5)
entries.append(VisibleEntry(index: index, item: item, x: x, y: y))
if entries.count >= 80 { break}
}
return entries
}
}

// MARK: - 弹幕设置表单

/// 弹幕设置表单：与 Flutter DanmakuSettings 逐项对齐，
/// 「我的 → 弹幕」页与播放设置面板共用同一份。
struct DanmakuSettingsForm: View {
@EnvironmentObject private var preferences: DanmakuPreferencesStore
@State private var showWords = false

var body: some View {
Group {
section("外观")
sliderRow(
"字号", subtitle: "相对默认字号的比例",
value: $preferences.scale, range: 0.6...2.0, step: 0.1
) { "\(Int(($0 * 100).rounded()))%"}
colorChips
sliderRow(
"透明度", subtitle: "调低后弹幕更透，不挡画面",
value: $preferences.opacity, range: 0.1...1.0, step: 0.05
) { "\(Int(($0 * 100).rounded()))%"}
Toggle(isOn: $preferences.bold) {
VStack(alignment:.leading, spacing: 2) {
Text("加粗")
Text("加粗的字在亮背景上更清楚")
.font(.caption)
.foregroundStyle(.secondary)
}
}
sliderRow(
"描边", subtitle: preferences.stroke == 0
? "关闭": "描边越粗字越突出",
value: $preferences.stroke, range: 0...6, step: 0.5
) { $0 == 0? "关闭": String(format: "%.1f", $0)}
sliderRow(
"阴影", subtitle: preferences.shadow == 0
? "关闭": "阴影越浓字越清晰",
value: $preferences.shadow, range: 0...12, step: 1
) { $0 == 0? "关闭": String(format: "%.1f", $0)}
section("滚动")
sliderRow(
"滚动速度", subtitle: "弹幕划过屏幕的快慢",
value: $preferences.speed, range: 0.5...2.0, step: 0.1
) { String(format: "%.1fx", $0)}
section("合并重复")
Text(
preferences.mergeSeconds == 0
? "关闭时每条弹幕单独滚动。"
: "时间相近、文字完全相同的弹幕并成一条，后面标上出现的次数。"
)
.font(.footnote)
.foregroundStyle(.secondary)
chipRow(
options: DanmakuPreferencesStore.merges.map { ($0.0, $0.1)},
selection: $preferences.merge
)
section("显示区域")
chipRow(
options: DanmakuPreferencesStore.coverages
.map { ($0.0, $0.1)},
selection: $preferences.coverage
)
section("屏蔽词")
Text(
preferences.words.isEmpty
? "没有屏蔽词，含屏蔽词的弹幕会直接不显示。"
: "已屏蔽 \(preferences.words.count) 个词："
+ preferences.words.joined(separator: "、")
)
.font(.footnote)
.foregroundStyle(.secondary)
Button {
showWords = true
} label: {
Label("管理屏蔽词", systemImage: "line.3.horizontal.decrease.circle")
}
.buttonStyle(.glass)
}
.sheet(isPresented: $showWords) {
DanmakuWordsEditor()
}
}

private func section(_ title: String) -> some View {
Text(title)
.font(.subheadline.weight(.bold))
.padding(.top, 8)
}

private func sliderRow(
_ title: String, subtitle: String,
value: Binding<Double>, range: ClosedRange<Double>, step: Double,
label: @escaping (Double) -> String
) -> some View {
VStack(alignment:.leading, spacing: 2) {
HStack {
Text(title)
Spacer()
Text(label(value.wrappedValue))
.foregroundStyle(.secondary)
.font(.callout)
}
Text(subtitle)
.font(.caption)
.foregroundStyle(.secondary)
Slider(value: value, in: range, step: step)
}
}

private var colorChips: some View {
HStack(spacing: 8) {
ForEach(
Array(DanmakuPreferencesStore.colors.enumerated()),
id: \.offset
) { index, value in
Button {
preferences.colorValue = value
} label: {
HStack(spacing: 6) {
Circle()
.fill(Color(argb: UInt32(
bitPattern: Int32(
truncatingIfNeeded: value
)
)))
.frame(width: 14, height: 14)
.overlay(Circle().stroke(.secondary.opacity(0.4)))
Text(DanmakuPreferencesStore.colorLabels[index])
.font(.callout)
}
.padding(.horizontal, 10)
.padding(.vertical, 6)
}
.buttonStyle(.glass)
.overlay(
Capsule().stroke(
preferences.colorValue == value
? Color.accentColor:.clear,
lineWidth: 1.5
)
)
}
}
}

private func chipRow(
options: [(String, String)], selection: Binding<String>
) -> some View {
HStack(spacing: 8) {
ForEach(options, id: \.0) { option in
Button(option.1) {
selection.wrappedValue = option.0
}
.buttonStyle(.glass)
.overlay(
Capsule().stroke(
selection.wrappedValue == option.0
? Color.accentColor:.clear,
lineWidth: 1.5
)
)
}
}
}
}

/// 屏蔽词管理：与 Flutter 的屏蔽词对话框同规则——
/// 单词 ≤40 字、总数 ≤60、按归一化文本去重。
struct DanmakuWordsEditor: View {
@EnvironmentObject private var preferences: DanmakuPreferencesStore
@Environment(\.dismiss) private var dismiss
@State private var draft: [String] = []
@State private var input = ""
@State private var error: String?

var body: some View {
NavigationStack {
Form {
Section {
HStack {
TextField("输入要屏蔽的词", text: $input)
.onSubmit(add)
Button("添加", action: add)
.disabled(
input.trimmingCharacters(
in:.whitespaces
).isEmpty
)
}
if let error {
Text(error)
.font(.footnote)
.foregroundStyle(.red)
}
}
Section {
if draft.isEmpty {
Text("还没有屏蔽词")
.foregroundStyle(.secondary)
} else {
ForEach(draft, id: \.self) { word in
HStack {
Text(word)
Spacer()
Button(role:.destructive) {
draft.removeAll { $0 == word}
} label: {
Image(systemName: "trash")
}
}
}
}
}
}
.navigationTitle("弹幕屏蔽词")
.navigationBarTitleDisplayMode(.inline)
.toolbar {
ToolbarItem(placement:.cancellationAction) {
Button("取消") { dismiss()}
}
ToolbarItem(placement:.confirmationAction) {
Button("保存") {
preferences.words = draft
dismiss()
}
}
}
.onAppear { draft = preferences.words}
}
.presentationBackground(.ultraThinMaterial)
}

private func add() {
let word = input.trimmingCharacters(in:.whitespaces)
guard !word.isEmpty else { return }
if word.count > 40 {
error = "单个屏蔽词最多 40 个字"
return
}
let key = normalizedDanmakuText(word)
if key.isEmpty {
error = "只有标点或空格的词无法匹配弹幕"
return
}
if draft.contains(where: { normalizedDanmakuText($0) == key}) {
error = "这个词已经在列表里了"
return
}
if draft.count >= 60 {
error = "最多只能添加 60 个屏蔽词"
return
}
draft.append(word)
input = ""
error = nil
}
}
