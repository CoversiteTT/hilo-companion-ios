import Combine
import CoreBluetooth
import Foundation

struct NearbyHilo: Identifiable {
    let peripheral: CBPeripheral
    let model: HiloModel
    let name: String
    let rssi: Int

    var id: UUID { peripheral.identifier }
}

final class HiloBluetooth: NSObject, ObservableObject {
    enum Phase { case idle, scanning, connecting, connected }

    private enum ProfilePurpose {
        case read, set(HeatingPreset), verify(HeatingPreset)

        var command: Data {
            if case let .set(preset) = self { return HiloProtocol.setProfile(preset) }
            return HiloProtocol.queryProfile
        }
    }

    private struct ProfileRequest {
        let purpose: ProfilePurpose
        var sent = false
        var acknowledged = false
        var reply: ProfileReply?
    }

    private struct HistorySync {
        let source: HistorySource
        var waitingForUnsubscribe: Bool
        var readRequested = false
        var expected: Int?
        var received = 0
        var invalidDates = 0
        var sessions: [UsageSession] = []
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var linkMessage = "未连接"
    @Published private(set) var nearby: [NearbyHilo] = []
    @Published private(set) var model: HiloModel?
    @Published private(set) var firmware: String?
    @Published private(set) var battery: Int?
    @Published private(set) var penBattery: Int?
    @Published private(set) var session: SessionState?
    @Published private(set) var profiles: AssignedProfiles?
    @Published private(set) var isProfileBusy = false
    @Published private(set) var profileMessage = "连接设备以读取当前档位。"
    @Published private(set) var history = UsageHistory()
    @Published private(set) var isSyncing = false
    @Published private(set) var historyMessage = "从设备同步记录。"
    @Published private(set) var hasHistoryStorageError = false

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [HiloCharacteristic: CBCharacteristic] = [:]
    @Published private var historySource: HistorySource?
    private var clockOffset: TimeInterval?
    private var profileRequest: ProfileRequest?
    @Published private var profileWriteInFlight = false
    private var historySync: HistorySync?
    private var linkTimer: DispatchWorkItem?
    private var profileTimer: DispatchWorkItem?
    private var historyTimer: DispatchWorkItem?
    private let store = HistoryStore()

    override init() {
        super.init()
        do {
            history = try store.load()
        } catch {
            hasHistoryStorageError = true
            historyMessage = "读取本地记录失败：\(error.localizedDescription)"
        }
    }

    var canReadProfiles: Bool {
        guard phase == .connected, !isProfileBusy, !profileWriteInFlight,
              let characteristic = characteristics[.heatingProfile],
              characteristic.properties.contains(.write) else { return false }
        return supportsNotifications(characteristic) && (model?.isPlus != true || session?.penPresent == true)
    }

    var canChangePreset: Bool {
        canReadProfiles && profiles != nil && session?.isActive == false
    }

    var canSyncHistory: Bool {
        guard phase == .connected, !isSyncing, !hasHistoryStorageError,
              historySource != nil, let characteristic = characteristics[.history] else { return false }
        return supportsNotifications(characteristic) && (model?.isPlus != true || session?.penPresent == true)
    }

    func scan() {
        guard phase == .idle else { return }
        nearby.removeAll()
        phase = .scanning
        linkMessage = "正在检查蓝牙…"
        if let manager {
            centralManagerDidUpdateState(manager)
        } else {
            manager = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stopScan() {
        guard phase == .scanning else { return }
        manager?.stopScan()
        linkTimer?.cancel()
        phase = .idle
        linkMessage = nearby.isEmpty ? "没找到 Hilo。请开启设备配对模式后再试。" : "请选择你的设备。"
    }

    func connect(_ device: NearbyHilo) {
        guard let manager, manager.state == .poweredOn,
              phase == .scanning || phase == .idle, peripheral == nil else { return }
        stopScan()
        nearby.removeAll()
        peripheral = device.peripheral
        device.peripheral.delegate = self
        phase = .connecting
        linkMessage = "正在连接 \(device.model.name)…"
        manager.connect(device.peripheral)
        linkTimer = schedule(after: 50) { [weak self] in
            self?.disconnect(message: "连接超时。请检查设备的配对状态和距离。")
        }
    }

    func disconnect() {
        if historySync != nil { finishHistory(ended: false) }
        disconnect(message: "已断开连接。")
    }

    func refreshDevice() {
        guard phase == .connected else { return }
        read(.clock)
        read(.information)
        read(.battery)
        read(.session)
        readProfiles()
    }

    private func readProfiles() {
        guard canReadProfiles else { return }
        startProfileRequest(.read)
    }

    func setPreset(_ preset: HeatingPreset) {
        guard canChangePreset, model?.presets.contains(preset) == true,
              profiles?.index(for: preset.mode) != preset.index else { return }
        startProfileRequest(.set(preset))
    }

    func syncHistory() {
        guard canSyncHistory, let peripheral, let source = historySource,
              let characteristic = characteristics[.history] else { return }
        historySync = HistorySync(source: source, waitingForUnsubscribe: characteristic.isNotifying)
        isSyncing = true
        historyMessage = "正在接收设备记录…"
        peripheral.setNotifyValue(!characteristic.isNotifying, for: characteristic)
        waitForHistory(seconds: 18)
    }

    private func disconnect(message: String) {
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        resetLink(message: message)
    }

    private func resetLink(message: String) {
        linkTimer?.cancel()
        profileTimer?.cancel()
        historyTimer?.cancel()
        peripheral?.delegate = nil
        peripheral = nil
        characteristics.removeAll()
        model = nil
        firmware = nil
        battery = nil
        penBattery = nil
        session = nil
        historySource = nil
        clockOffset = nil
        profileRequest = nil
        profileWriteInFlight = false
        profiles = nil
        isProfileBusy = false
        profileMessage = "连接设备以读取当前档位。"
        if historySync != nil { abortHistory("连接已断开，请重新同步。") }
        phase = .idle
        linkMessage = message
    }

    private func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    private func supportsNotifications(_ characteristic: CBCharacteristic) -> Bool {
        !characteristic.properties.intersection([.notify, .indicate]).isEmpty
    }

    @discardableResult
    private func read(_ kind: HiloCharacteristic) -> Bool {
        guard let peripheral, let characteristic = characteristics[kind],
              characteristic.properties.contains(.read) else { return false }
        peripheral.readValue(for: characteristic)
        return true
    }

    private func kind(of characteristic: CBCharacteristic) -> HiloCharacteristic? {
        characteristics.first { $0.value === characteristic }?.key
    }

    private func message(for error: Error) -> String {
        let details = error as NSError
        if details.domain == CBATTErrorDomain, [5, 8, 12, 15].contains(details.code) {
            return "设备要求授权。请完成 iPhone 的配对提示，或先用官方客户端启用设备。"
        }
        return error.localizedDescription
    }

    private func startProfileRequest(_ purpose: ProfilePurpose) {
        guard let peripheral, let characteristic = characteristics[.heatingProfile] else { return }
        isProfileBusy = true
        profileRequest = ProfileRequest(purpose: purpose)
        profileMessage = "正在确认设备档位…"
        profileTimer?.cancel()
        profileTimer = schedule(after: 12) { [weak self] in
            self?.finishProfile("设备未响应。请刷新档位，必要时重新连接。", clearProfiles: true)
        }
        if characteristic.isNotifying {
            sendProfileRequest()
        } else {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func sendProfileRequest() {
        guard let peripheral, let characteristic = characteristics[.heatingProfile],
              var request = profileRequest, !request.sent, !profileWriteInFlight else { return }
        if case .set = request.purpose, session?.isActive != false || model?.isPlus == true && session?.penPresent != true {
            let message = session?.isActive == true ? "请等当前加热结束。" : "请确认设备处于空闲状态。"
            finishProfile(message, clearProfiles: false)
            return
        }
        request.sent = true
        profileRequest = request
        profileWriteInFlight = true
        peripheral.writeValue(request.purpose.command, for: characteristic, type: .withResponse)
    }

    private func receiveProfile(_ data: Data) {
        guard var request = profileRequest, request.sent, let reply = HiloProtocol.profileReply(data) else { return }
        switch (request.purpose, reply) {
        case (.set, .result), (.read, .assigned), (.verify, .assigned):
            request.reply = reply
            profileRequest = request
            completeProfileRequest()
        default:
            break
        }
    }

    private func completeProfileRequest() {
        guard let request = profileRequest, request.acknowledged, let reply = request.reply else { return }
        switch (request.purpose, reply) {
        case (.read, .assigned(let values)):
            profiles = values
            finishProfile("当前档位已从设备读取。", clearProfiles: false)
        case (.set(let preset), .result(true)):
            startProfileRequest(.verify(preset))
        case (.set, .result(false)):
            finishProfile("设备拒绝了这次设置。", clearProfiles: false)
        case (.verify(let preset), .assigned(let values)):
            profiles = values
            let confirmed = values.index(for: preset.mode) == preset.index
            finishProfile(confirmed ? "已保存并从设备确认。" : "设备回报的档位与所选档位不同。", clearProfiles: false)
        default:
            break
        }
    }

    private func finishProfile(_ message: String, clearProfiles: Bool) {
        profileTimer?.cancel()
        profileRequest = nil
        isProfileBusy = false
        if clearProfiles { profiles = nil }
        profileMessage = message
    }

    private func waitForHistory(seconds: TimeInterval) {
        historyTimer?.cancel()
        historyTimer = schedule(after: seconds) { [weak self] in self?.finishHistory(ended: false) }
    }

    private func receiveHistory(_ data: Data) {
        guard var sync = historySync, !sync.waitingForUnsubscribe,
              let model, let packet = HiloProtocol.historyPacket(data, model: model) else { return }
        switch packet {
        case .count(let count):
            if sync.expected == nil { sync.expected = count }
        case .start(let count):
            if let count { sync.expected = count }
        case .end:
            finishHistory(ended: true)
            return
        case .records(let records):
            sync.received += records.count
            let now = Date()
            for record in records where record.exitCode <= 2 {
                guard let date = record.date(offset: clockOffset, now: now) else {
                    sync.invalidDates += 1
                    continue
                }
                sync.sessions.append(UsageSession(source: sync.source, sequence: record.sequence,
                                                  deviceTimestamp: record.timestamp, date: date, mode: record.mode))
            }
        }
        historySync = sync
        if sync.received > 0 { historyMessage = "已收到 \(sync.received) 条记录…" }
        waitForHistory(seconds: 8)
    }

    private func finishHistory(ended: Bool) {
        guard let sync = historySync else { return }
        historyTimer?.cancel()
        historySync = nil
        isSyncing = false
        guard ended || sync.expected == 0 || sync.received > 0 else {
            historyMessage = sync.expected.map { "设备报告 \($0) 条待同步记录，本次没有收到记录内容。" }
                ?? "未收到记录。请保持设备连接后重试。"
            return
        }
        let updated = store.merging(sync.sessions, into: history, at: Date())
        do {
            try store.save(updated)
            let added = updated.sessions.count - history.sessions.count
            history = updated
            if let expected = sync.expected, sync.received < expected {
                historyMessage = "本次收到 \(sync.received)/\(expected) 条，保存了 \(added) 条新记录。"
            } else if sync.received == 0 {
                historyMessage = "设备没有待同步的记录。"
            } else {
                historyMessage = "收到 \(sync.received) 条记录，新增 \(added) 条。"
            }
            if sync.invalidDates > 0 { historyMessage += " \(sync.invalidDates) 条时间无法确认。" }
        } catch {
            historyMessage = "保存记录失败：\(error.localizedDescription)"
        }
    }

    private func abortHistory(_ message: String) {
        historyTimer?.cancel()
        historySync = nil
        isSyncing = false
        historyMessage = message
    }

    private func updateSession(_ data: Data, model: HiloModel) {
        guard let updated = SessionState(data, model: model) else { return }
        let previous = session
        session = updated
        if model.isPlus && previous?.penPresent != updated.penPresent {
            if previous != nil || !updated.penPresent {
                historySource = nil
                profiles = nil
                if historySync != nil { abortHistory("加热笔状态已改变，请重新同步。") }
                if profileRequest != nil { finishProfile("请放回加热笔再读取档位。", clearProfiles: true) }
            }
            if updated.penPresent {
                read(.information)
                read(.battery)
                readProfiles()
            } else {
                penBattery = nil
                profileMessage = "请把加热笔放入充电盒。"
            }
        }
    }
}

extension HiloBluetooth: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard phase == .scanning, !central.isScanning else { return }
            linkMessage = "正在搜索 Hilo 和 Hilo Plus…"
            let services = HiloModel.allCases.map { CBUUID(string: $0.serviceID) }
            central.scanForPeripherals(withServices: services, options: nil)
            linkTimer = schedule(after: 25) { [weak self] in self?.stopScan() }
        case .poweredOff:
            resetLink(message: "请开启 iPhone 蓝牙后再搜索。")
        case .unauthorized:
            resetLink(message: "请在 iPhone 设置中允许 Hilo 连接使用蓝牙。")
        case .unsupported:
            resetLink(message: "此设备不支持蓝牙低功耗连接。")
        case .unknown, .resetting:
            break
        @unknown default:
            resetLink(message: "蓝牙暂时不可用。")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .scanning else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let advertised = Set(services + Array(serviceData.keys) + overflow)
        guard let model = HiloModel.allCases.first(where: { advertised.contains(CBUUID(string: $0.serviceID)) }) else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? model.name
        nearby.removeAll { $0.id == peripheral.identifier }
        nearby.append(NearbyHilo(peripheral: peripheral, model: model, name: name, rssi: RSSI.intValue))
        nearby.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        linkMessage = "正在识别设备服务…"
        peripheral.discoverServices(HiloModel.allCases.map { CBUUID(string: $0.serviceID) })
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        resetLink(message: error.map { message(for: $0) } ?? "连接失败。请重新搜索。")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if historySync != nil { finishHistory(ended: false) }
        resetLink(message: error.map { message(for: $0) } ?? "设备已断开连接。")
    }
}

extension HiloBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        for service in peripheral.services ?? [] {
            if let found = HiloModel.allCases.first(where: { CBUUID(string: $0.serviceID) == service.uuid }) {
                model = found
                peripheral.discoverCharacteristics(HiloCharacteristic.allCases.map { CBUUID(string: found.uuid($0)) }, for: service)
                return
            }
        }
        disconnect(message: error.map { message(for: $0) } ?? "没有找到受支持的 Hilo 服务。")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, let model else { return }
        if let error { disconnect(message: message(for: error)); return }
        for characteristic in service.characteristics ?? [] {
            if let field = HiloCharacteristic.allCases.first(where: { CBUUID(string: model.uuid($0)) == characteristic.uuid }) {
                characteristics[field] = characteristic
            }
        }
        guard !characteristics.isEmpty else { disconnect(message: "设备没有提供可识别的蓝牙特征。"); return }
        linkTimer?.cancel()
        phase = .connected
        linkMessage = "已连接"
        refreshDevice()
        if let state = characteristics[.session], supportsNotifications(state) {
            peripheral.setNotifyValue(true, for: state)
        }
        if characteristics[.heatingProfile] == nil { profileMessage = "设备没有报告时长设置特征。" }
        if characteristics[.history] == nil && !hasHistoryStorageError { historyMessage = "设备没有报告使用记录特征。" }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, let field = kind(of: characteristic) else { return }
        switch field {
        case .heatingProfile:
            if let error, profileRequest != nil {
                finishProfile(message(for: error), clearProfiles: true)
            } else if characteristic.isNotifying {
                sendProfileRequest()
            }
        case .history:
            guard var sync = historySync else { return }
            if let error { abortHistory(message(for: error)); return }
            if !characteristic.isNotifying && sync.waitingForUnsubscribe {
                sync.waitingForUnsubscribe = false
                historySync = sync
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.isNotifying && !sync.readRequested {
                sync.readRequested = true
                historySync = sync
                read(.history)
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, kind(of: characteristic) == .heatingProfile else { return }
        profileWriteInFlight = false
        guard var request = profileRequest else { return }
        if let error { finishProfile(message(for: error), clearProfiles: true); return }
        request.acknowledged = true
        profileRequest = request
        completeProfileRequest()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, let model, let field = kind(of: characteristic) else { return }
        if let error {
            switch field {
            case .heatingProfile where profileRequest != nil:
                finishProfile(message(for: error), clearProfiles: true)
            case .history where historySync != nil:
                historyMessage = message(for: error)
            case .information, .session:
                linkMessage = message(for: error)
            default:
                break
            }
            return
        }
        guard let data = characteristic.value else { return }
        switch field {
        case .information:
            guard let info = HiloDeviceInfo(data, model: model) else { return }
            firmware = info.firmware
            if model.isPlus && session?.penPresent == false { return }
            if let sync = historySync, info.historySource?.id != sync.source.id {
                abortHistory("设备或加热笔已改变，请重新同步。")
            }
            historySource = info.historySource
            linkMessage = "已连接"
        case .clock:
            clockOffset = HiloProtocol.clockOffset(data, now: Date())
        case .battery:
            let bytes = [UInt8](data)
            battery = bytes.first.flatMap { $0 <= 100 ? Int($0) : nil }
            let index = model.is15 ? 4 : 3
            if model.isPlus, session?.penPresent != false, bytes.count > index, bytes[index] <= 100 {
                penBattery = Int(bytes[index])
            }
        case .session:
            updateSession(data, model: model)
        case .heatingProfile:
            receiveProfile(data)
        case .history:
            receiveHistory(data)
        }
    }
}
