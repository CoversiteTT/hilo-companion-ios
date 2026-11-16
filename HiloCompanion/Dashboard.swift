import Charts
import SwiftUI
import UIKit

struct Dashboard: View {
    @ObservedObject var bluetooth: HiloBluetooth
    @State private var preset: HeatingPreset?
    @State private var period: UsagePeriod = .week
    @State private var source: String?

    private enum UsagePeriod: String, CaseIterable, Identifiable {
        case today = "今天"
        case week = "近 7 天"
        case month = "近 30 天"

        var id: Self { self }

        var days: Int {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 30
            }
        }
    }

    private struct DayCount: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    private var sources: [HistorySource] {
        Set(bluetooth.history.sessions.map(\.source)).sorted { $0.label < $1.label }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    connectionCard
                    heatingCard
                    usageCard
                }
                .frame(maxWidth: 620)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Hilo 连接")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: bluetooth.phase) { phase in
            if phase != .connected { preset = nil }
        }
        .onChange(of: bluetooth.session?.penPresent) { present in
            if present != true { preset = nil }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: bluetooth.phase == .connected ? "link" : "link.badge.plus")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bluetooth.model?.name ?? "设备连接").font(.headline)
                    Text(bluetooth.linkMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if bluetooth.phase == .connecting { ProgressView().controlSize(.small) }
            }

            if bluetooth.phase == .connected {
                if let battery = bluetooth.battery {
                    Label("\(bluetooth.model?.isPlus == true ? "充电盒" : "电量") \(battery)%", systemImage: "battery.75percent")
                        .font(.subheadline)
                }
                if let penBattery = bluetooth.penBattery {
                    Label("加热笔 \(penBattery)%", systemImage: "battery.75percent").font(.subheadline)
                }
                if let firmware = bluetooth.firmware {
                    Text("固件 \(firmware)").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("刷新设备", action: bluetooth.refreshDevice)
                    Spacer()
                    Button("断开", action: bluetooth.disconnect)
                }
                .font(.subheadline.weight(.semibold))
            } else if bluetooth.phase == .connecting {
                Button("取消连接", action: bluetooth.disconnect).font(.subheadline)
            } else {
                Text("连按设备控制键 5 次进入配对模式。Hilo Plus 通过充电盒连接。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(bluetooth.nearby) { device in
                    Button { bluetooth.connect(device) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.subheadline.weight(.semibold))
                                Text(device.model.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("连接").font(.subheadline)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .padding(10)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                Button(bluetooth.phase == .scanning ? "停止搜索" : "搜索设备") {
                    if bluetooth.phase == .scanning { bluetooth.stopScan() } else { bluetooth.scan() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .card()
    }

    private var heatingCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("加热时长", systemImage: "timer").font(.headline)
            if bluetooth.phase == .connected, let model = bluetooth.model, let profiles = bluetooth.profiles {
                ForEach(HeatingMode.allCases, id: \.self) { mode in
                    let options = model.presets.filter { $0.mode == mode }
                    if !options.isEmpty {
                        Text(mode.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(options) { choice in
                            presetRow(choice, isCurrent: choice.index == profiles.index(for: mode))
                        }
                    }
                }
            }
            if bluetooth.isProfileBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(bluetooth.profileMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text(bluetooth.session?.isActive == true ? "当前正在加热，结束后可调整时长。" : bluetooth.profileMessage)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let preset, bluetooth.profiles?.index(for: preset.mode) != preset.index {
                Button("保存档位") {
                    bluetooth.setPreset(preset)
                    self.preset = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(!bluetooth.canChangePreset)
            }
        }
        .card()
    }

    private func presetRow(_ choice: HeatingPreset, isCurrent: Bool) -> some View {
        Button { preset = choice } label: {
            HStack(spacing: 8) {
                Image(systemName: preset == choice ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(preset == choice ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(choice.title).font(.subheadline)
                Spacer(minLength: 4)
                if isCurrent {
                    Text("当前").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(preset == choice ? .isSelected : [])
        .disabled(!bluetooth.canChangePreset)
    }

    private var usageCard: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let first = calendar.date(byAdding: .day, value: 1 - period.days, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let sessions = bluetooth.history.sessions.filter {
            $0.date >= first && $0.date < end && (source == nil || source == $0.source.id)
        }
        let counts = Dictionary(grouping: sessions, by: { calendar.startOfDay(for: $0.date) })
        let days = (0..<period.days).compactMap { index -> DayCount? in
            guard let date = calendar.date(byAdding: .day, value: index, to: first) else { return nil }
            return DayCount(date: date, count: counts[date]?.count ?? 0)
        }

        return VStack(alignment: .leading, spacing: 12) {
            Label("使用统计", systemImage: "chart.bar.xaxis").font(.headline)
            Picker("统计周期", selection: $period) {
                ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if sources.count > 1 {
                Picker("统计设备", selection: $source) {
                    Text("全部设备").tag(Optional<String>.none)
                    ForEach(sources) { Text($0.label).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
            }
            if bluetooth.history.sessions.isEmpty {
                Text("手机里还没有用量记录。").font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sessions.count.formatted()).font(.largeTitle.bold().monospacedDigit())
                    Text("次").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 18) {
                    Text("标准 \(sessions.filter { $0.mode == .standard }.count)")
                    Text("Boost \(sessions.filter { $0.mode == .boost }.count)")
                }
                .font(.footnote).foregroundStyle(.secondary)
                if period != .today && !sessions.isEmpty {
                    Chart(days) { day in
                        BarMark(x: .value("日期", day.date, unit: .day), y: .value("次数", day.count))
                            .cornerRadius(4)
                            .foregroundStyle(.tint)
                            .accessibilityLabel(day.date.formatted(.dateTime.month().day()))
                            .accessibilityValue("\(day.count) 次")
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                    .frame(height: 130)
                }
            }
            if let lastSync = bluetooth.history.lastSync {
                Text("上次同步 \(lastSync.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if bluetooth.model?.isPlus == true && bluetooth.session?.penPresent == false {
                Text("请把加热笔放入充电盒再同步。").font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if bluetooth.isSyncing { ProgressView().controlSize(.small) }
                Text(bluetooth.historyMessage).font(.footnote).foregroundStyle(.secondary)
            }
            Button("同步记录", action: bluetooth.syncHistory)
                .buttonStyle(.bordered)
                .disabled(!bluetooth.canSyncHistory)
        }
        .card()
    }
}

private extension View {
    func card() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
