import SwiftUI
import UsageCore

struct SettingsView: View {
    @Bindable var store: UsageMonitorStore
    @Bindable var preferences: AppPreferences

    var body: some View {
        TabView {
            menuBarTab
                .tabItem { Label("菜单栏", systemImage: "menubar.rectangle") }

            panelLayoutTab
                .tabItem { Label("面板布局", systemImage: "rectangle.3.group") }

            bridgeTab
                .tabItem { Label("CLI 桥接", systemImage: "terminal") }
        }
        .padding(16)
        .frame(width: 440, height: 340)
        .onAppear {
            preferences.syncLaunchAtLoginStatus()
        }
    }

    private var menuBarTab: some View {
        Form {
            Section("菜单栏显示列") {
                Toggle("5 小时限额（默认）", isOn: $preferences.showFiveHourInMenuBar)
                Toggle("周限额", isOn: $preferences.showWeeklyInMenuBar)
                Toggle("今日缓存命中率", isOn: $preferences.showCacheRateInMenuBar)
                Toggle("今日估算花费", isOn: $preferences.showTodayCostInMenuBar)
                Toggle("当前会话上下文占比", isOn: $preferences.showContextInMenuBar)
            }
            .onChange(of: preferences.showFiveHourInMenuBar) { store.onMenuBarUpdate?() }
            .onChange(of: preferences.showWeeklyInMenuBar) { store.onMenuBarUpdate?() }
            .onChange(of: preferences.showCacheRateInMenuBar) { store.onMenuBarUpdate?() }
            .onChange(of: preferences.showTodayCostInMenuBar) { store.onMenuBarUpdate?() }
            .onChange(of: preferences.showContextInMenuBar) { store.onMenuBarUpdate?() }

            Section("常规") {
                Picker("定时刷新间隔", selection: $preferences.refreshIntervalSeconds) {
                    Text("10 秒").tag(10)
                    Text("30 秒（推荐）").tag(30)
                    Text("60 秒").tag(60)
                    Text("5 分钟").tag(300)
                }
                .onChange(of: preferences.refreshIntervalSeconds) {
                    store.restartTimer()
                }

                Toggle("开机自动启动", isOn: Binding(
                    get: { preferences.launchAtLoginEnabled },
                    set: { preferences.setLaunchAtLogin($0) }
                ))

                if let err = preferences.launchAtLoginError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var panelLayoutTab: some View {
        Form {
            Section("弹窗面板区块密度") {
                Picker("官方限额区", selection: $preferences.quotaSectionDensity) {
                    ForEach(SectionDensity.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("活跃会话上下文区", selection: $preferences.contextSectionDensity) {
                    ForEach(SectionDensity.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("本地 Token 与缓存区", selection: $preferences.localSectionDensity) {
                    ForEach(SectionDensity.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var bridgeTab: some View {
        Form {
            Section("agy statusLine 桥接状态") {
                LabeledContent("当前状态") {
                    switch store.bridgeStatus {
                    case .installedDirect:
                        Label("已接入（保留默认状态栏）", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .installedChained(let original):
                        Label("已链式包装原脚本", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help(original)
                    case .notInstalled(let existing):
                        if let existing {
                            Label("未接入（检测到已有自定义脚本）", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                                .help(existing)
                        } else {
                            Label("未接入", systemImage: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("配置文件") {
                    Text(store.bridgeInstaller.settingsURL.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("快照文件") {
                    Text(store.bridgeInstaller.snapshotURL.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button(store.bridgeStatus.isInstalled ? "重新写入桥接" : "一键安全接入") {
                        store.installBridge()
                    }
                    .buttonStyle(.borderedProminent)

                    if store.bridgeStatus.isInstalled {
                        Button("一键卸载并还原") {
                            store.uninstallBridge()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let feedback = store.bridgeFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}
