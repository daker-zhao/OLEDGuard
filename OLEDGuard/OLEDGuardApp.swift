import SwiftUI
import ServiceManagement

@main
struct OLEDGuardApp: App {
    @StateObject private var controller = OLEDController()
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    var body: some Scene {
        MenuBarExtra {
            OLEDMenuContent(controller: controller, launchAtLogin: $launchAtLogin)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "shield.checkerboard")
                if !controller.countdownText.isEmpty {
                    Text(controller.countdownText).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor((controller.isMonitoringEnabled && controller.selectedScreen != nil) ? .primary : .secondary)
                }
            }
        }.menuBarExtraStyle(.window)
    }
}

struct OLEDMenuContent: View {
    @ObservedObject var controller: OLEDController
    @Binding var launchAtLogin: Bool
    @State private var newName: String = ""
    @State private var isAdd: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderSection(controller: controller)
            Divider()
            VStack(spacing: 12) {
                StrategyGroup(controller: controller)
                AnalysisGroup(controller: controller)
                WakeGroup(controller: controller)
                HotkeyGroup(controller: controller)
                PhysicalMaskGroup(controller: controller, isAdd: $newName, isAddActive: $isAdd)
            }
            Divider()
            FooterSection(controller: controller, launchAtLogin: $launchAtLogin)
        }.padding(16).frame(width: 300)
    }
}

// MARK: - 🧱 子组件

struct HeaderSection: View {
    @ObservedObject var controller: OLEDController
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("OLED Guard Pro").font(.system(size: 15, weight: .bold))
                Text(controller.statusMessage).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $controller.isMonitoringEnabled).toggleStyle(.switch).controlSize(.mini)
        }.padding(.top, 4)
    }
}

struct StrategyGroup: View {
    @ObservedObject var controller: OLEDController
    var body: some View {
        DisclosureGroup("递进检测模式 (含门槛)") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("1. 宽松检测", isOn: $controller.enableRelaxedMode).font(.caption).tint(.blue)
                if controller.enableRelaxedMode {
                    ConfigRow(label: "   容忍时长(X)", suffix: "s", value: $controller.maxIdleX)
                    HStack {
                        Toggle("活跃门槛", isOn: $controller.enableRelaxedGridLimit).labelsHidden().controlSize(.mini)
                        Text("活跃门槛").font(.caption2).foregroundColor(.secondary)
                        Slider(value: $controller.relaxedGridThreshold, in: 1...20, step: 1).controlSize(.mini)
                        Text("\(Int(controller.relaxedGridThreshold))格").font(.caption2.monospaced())
                    }
                }
                
                Toggle("2. 严格检测", isOn: $controller.enableStrictMode).font(.caption).tint(.orange)
                if controller.enableStrictMode {
                    ConfigRow(label: "   容忍时长(Y)", suffix: "s", value: $controller.maxIdleY)
                    HStack {
                        Toggle("活跃门槛", isOn: $controller.enableStrictGridLimit).labelsHidden().controlSize(.mini)
                        Text("活跃门槛").font(.caption2).foregroundColor(.secondary)
                        Slider(value: $controller.strictGridThreshold, in: 1...30, step: 1).controlSize(.mini)
                        Text("\(Int(controller.strictGridThreshold))格").font(.caption2.monospaced())
                    }
                }
                
                Toggle("3. 强制检测", isOn: $controller.enableForcedMode).font(.caption).tint(.red)
                if controller.enableForcedMode {
                    ConfigRow(label: "   容忍时长(Z)", suffix: "s", value: $controller.maxIdleZ)
                    HStack {
                        Toggle("终审门槛", isOn: $controller.enableForcedGridLimit).labelsHidden().controlSize(.mini)
                        Text("终审门槛").font(.caption2).foregroundColor(.secondary)
                        Slider(value: $controller.forcedGridThreshold, in: 1...50, step: 1).controlSize(.mini)
                        Text("\(Int(controller.forcedGridThreshold))格").font(.caption2.monospaced())
                    }
                }
            }.padding(.vertical, 8)
        }
    }
}

struct AnalysisGroup: View {
    @ObservedObject var controller: OLEDController
    var body: some View {
        DisclosureGroup("视觉采样基准") {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("采样灵敏度").font(.system(size: 12)).foregroundColor(.secondary); Spacer(); Text("\(controller.sensitivityArea, specifier: "%.1f")%").font(.system(size: 12, design: .monospaced)) }
                    Slider(value: $controller.sensitivityArea, in: 0.1...5.0, step: 0.1).controlSize(.mini)
                }
                ConfigRow(label: "巡逻频率", suffix: "s/次", value: $controller.patrolInterval)
                HStack { Text("分析分辨率").font(.system(size: 12)).foregroundColor(.secondary); Spacer(); MiniPicker(selection: $controller.resStage1).onChange(of: controller.resStage1) { _, val in controller.currentRes = val } }
            }.padding(.vertical, 8)
        }
    }
}

struct WakeGroup: View {
    @ObservedObject var controller: OLEDController
    var body: some View {
        DisclosureGroup("进阶休眠策略 (双轨)") {
            VStack(spacing: 10) {
                ConfigRow(label: "初始唤醒频率", suffix: "s/次", value: $controller.wakeInterval)
                ConfigRow(label: "深度节能时限", suffix: "s", value: $controller.deepSleepDelay)
                ConfigRow(label: "深度唤醒频率", suffix: "s/次", value: $controller.deepSleepInterval)
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("深度噪点阈值").font(.system(size: 12)).foregroundColor(.secondary); Spacer(); Text("\(controller.deepSleepSensitivity, specifier: "%.1f")%").font(.system(size: 12, design: .monospaced)) }
                    Slider(value: $controller.deepSleepSensitivity, in: 0.1...5.0, step: 0.1).controlSize(.mini)
                }
                Divider()
                Text("双轨回退特赦 (唤醒时)").font(.caption2).foregroundColor(.blue)
                if controller.enableStrictMode {
                    HStack {
                        Toggle("严格回退", isOn: $controller.enableStrictDual).labelsHidden().controlSize(.mini)
                        Text("严格回退").font(.caption2).foregroundColor(.secondary)
                        Slider(value: $controller.strictDualThreshold, in: 1...40, step: 1).controlSize(.mini)
                        Text("> \(Int(controller.strictDualThreshold))格").font(.caption2.monospaced())
                    }
                }
                if controller.enableForcedMode {
                    HStack {
                        Toggle("强制回退", isOn: $controller.enableForcedDual).labelsHidden().controlSize(.mini)
                        Text("强制回退").font(.caption2).foregroundColor(.secondary)
                        Slider(value: $controller.forcedDualThreshold, in: 1...60, step: 1).controlSize(.mini)
                        Text("> \(Int(controller.forcedDualThreshold))格").font(.caption2.monospaced())
                    }
                }
            }.padding(.vertical, 8)
        }
    }
}

struct HotkeyGroup: View {
    @ObservedObject var controller: OLEDController
    var body: some View {
        DisclosureGroup("快捷键保护墙") {
            VStack(spacing: 10) {
                HStack { Text("触发后保护:").font(.system(size: 12)); Spacer(); TextField("", value: $controller.screenshotDelay, format: .number).textFieldStyle(.roundedBorder).frame(width: 40); Text("s").font(.caption2) }
                VStack(spacing: 4) {
                    ForEach(controller.screenshotShortcuts) { sc in
                        HStack { Text(sc.readableString).font(.system(size: 11, design: .monospaced)).padding(4).background(Color.gray.opacity(0.1)).cornerRadius(4); Spacer()
                            Button(action: { controller.screenshotShortcuts.removeAll(where: { $0.id == sc.id }) }) { Image(systemName: "xmark.circle.fill").foregroundColor(.red).opacity(0.7) }.buttonStyle(.plain) }
                    }
                }
                Button(action: { controller.startHotkeyCapture() }) {
                    HStack { Image(systemName: controller.isHotkeyIntercepting ? "record.circle.fill" : "keyboard"); Text(controller.isHotkeyIntercepting ? "监听按键中..." : "新增组合键") }
                    .frame(maxWidth: .infinity).padding(.vertical, 4).background(Color.blue.opacity(0.1)).cornerRadius(6)
                }.buttonStyle(.plain).foregroundColor(.blue)
            }.padding(.vertical, 8)
        }
    }
}

struct PhysicalMaskGroup: View {
    @ObservedObject var controller: OLEDController
    @Binding var isAdd: String; @Binding var isAddActive: Bool
    var body: some View {
        DisclosureGroup("目标屏幕与遮罩") {
            VStack(spacing: 12) {
                HStack {
                    Text("预设方案:").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Menu {
                        Button("保存当前") { isAddActive = true }
                        Divider()
                        ForEach(controller.maskPresets) { p in Button(p.name) { controller.applyPreset(p) } }
                    } label: { Text("切换").font(.caption); Image(systemName: "chevron.up.chevron.down").font(.caption2) }.menuStyle(.borderedButton).controlSize(.mini)
                }
                if isAddActive {
                    HStack {
                        TextField("名称", text: $isAdd).textFieldStyle(.roundedBorder).controlSize(.mini)
                        Button("确认") { controller.saveCurrentAsPreset(name: isAdd); isAdd = ""; isAddActive = false }.controlSize(.mini)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        Toggle("状态栏遮罩", isOn: $controller.enableOverlayTop).font(.caption)
                        if controller.enableOverlayTop { Slider(value: $controller.topVisualPadding, in: 0...600).controlSize(.mini) }
                        Toggle("Dock栏遮罩", isOn: $controller.enableOverlayBottom).font(.caption)
                        if controller.enableOverlayBottom {
                            Toggle("智能吸附边界", isOn: $controller.dockSmartBoundary).font(.caption2).foregroundColor(.secondary).controlSize(.mini)
                            Slider(value: $controller.dockVisualPadding, in: 0...600).controlSize(.mini)
                        }
                    }
                    Divider()
                    Text("自定义遮罩（四周）").font(.caption2).foregroundColor(.blue)
                    Grid {
                        GridRow { ManualSlider(l: "左", v: $controller.manualMaskLeft); ManualSlider(l: "右", v: $controller.manualMaskRight) }
                        GridRow { ManualSlider(l: "上", v: $controller.manualMaskTop); ManualSlider(l: "下", v: $controller.manualMaskBottom) }
                    }
                    if controller.enableOverlayTop || controller.enableOverlayBottom || controller.manualMaskTop > 0 || controller.manualMaskBottom > 0 || controller.manualMaskLeft > 0 || controller.manualMaskRight > 0 {
                        HStack { Text("移开恢复时间:").font(.caption2).foregroundColor(.secondary); Slider(value: $controller.overlayRestoreDelay, in: 0.5...10.0, step: 0.5).controlSize(.mini); Text("\(controller.overlayRestoreDelay, specifier: "%.1f")s").font(.caption2.monospaced()) }
                    }
                }.padding(8).background(Color.black.opacity(0.05)).cornerRadius(6)
                Divider()
                Text("视觉检测屏蔽区(%)").font(.caption2).foregroundColor(.secondary)
                HStack { LabelInput(label: "上", val: $controller.maskTop); LabelInput(label: "下", val: $controller.maskBottom); LabelInput(label: "左", val: $controller.maskLeft); LabelInput(label: "右", val: $controller.maskRight) }
                Divider()
                VStack(spacing: 2) { ForEach(NSScreen.screens, id: \.self) { s in ScreenRow(name: s.localizedName, isSelected: controller.selectedScreen == s) { controller.saveSelection(screen: s) } } }
            }.padding(.vertical, 8)
        }
    }
}

struct FooterSection: View {
    @ObservedObject var controller: OLEDController; @Binding var launchAtLogin: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("显示运行状态", isOn: $controller.showStatusText).font(.caption); Spacer()
                Toggle("开机自启", isOn: $launchAtLogin).font(.caption).onChange(of: launchAtLogin) { _, n in try? (n ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }
            }
            if !controller.hasAccessibilityAccess { Button("辅助功能权限") { controller.requestAccessibilityPermission() }.buttonStyle(.borderedProminent).controlSize(.small).tint(.orange) }
            if !controller.hasScreenAccess { Button("录屏视觉权限") { controller.requestScreenRecordingPermission() }.buttonStyle(.borderedProminent).controlSize(.small).tint(.blue) }
            HStack { Spacer(); Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.bordered).controlSize(.small) }
        }
    }
}

// 辅助组件
struct ManualSlider: View { let l: String; @Binding var v: Double; var body: some View { HStack { Text(l).font(.caption2).frame(width:12); Slider(value: $v, in: 0...600).controlSize(.mini) } } }
struct ConfigRow: View { let label: String; let suffix: String; @Binding var value: Double; var body: some View { HStack { Text(label).font(.system(size: 12)).foregroundColor(.secondary); Spacer(); TextField("", value: $value, format: .number).font(.system(size: 12, design: .monospaced)).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 50); Text(suffix).font(.caption2).foregroundColor(.secondary).frame(width: 30) } } }
struct LabelInput: View { let label: String; @Binding var val: Double; var body: some View { VStack(spacing: 2) { Text(label).font(.caption2).foregroundColor(.secondary); TextField("", value: $val, format: .number).font(.caption.monospaced()).multilineTextAlignment(.center).textFieldStyle(.roundedBorder) } } }
struct ScreenRow: View { let name: String; let isSelected: Bool; let action: () -> Void; var body: some View { Button(action: action) { HStack { Image(systemName: "display").foregroundColor(isSelected ? .blue : .gray); Text(name).font(.system(size: 11)).lineLimit(1); Spacer(); if isSelected { Image(systemName: "checkmark").font(.caption).foregroundColor(.blue) } }.padding(8).background(isSelected ? Color.blue.opacity(0.05) : Color.clear).cornerRadius(4) }.buttonStyle(.plain) } }
struct MiniPicker: View { @Binding var selection: Int; let options = [64, 128, 256, 512, 1024]; var body: some View { Menu { ForEach(options, id: \.self) { opt in Button("\(opt)x") { selection = opt } } } label: { Text("\(selection)").font(.caption).frame(width: 30) }.menuStyle(.borderlessButton).frame(width: 50, height: 20).background(Color.gray.opacity(0.1)).cornerRadius(4) } }
