// Native macOS app for the LILO: read the configuration, set the light mode and lighting window.
// Build with scripts/make-macos-app.sh. Protocol: see README.md.

import CoreBluetooth
import SwiftUI

let lightNames = [String(localized: "Off"), String(localized: "Photo"), String(localized: "Spring"), String(localized: "Summer")]
let lightDescriptions = [String(localized: "Light stays off."), String(localized: "20% intensity."),
                         String(localized: "75% intensity."), String(localized: "100% intensity.")]

let serviceUUID = CBUUID(string: "53E11631-B840-4B21-93CE-081726DDC739")
let lightUUID = CBUUID(string: "53E11632-B840-4B21-93CE-081726DDC739")
let timeUUID = CBUUID(string: "53E11633-B840-4B21-93CE-081726DDC739")
let clockServiceUUID = CBUUID(string: "53E12188-B840-4B21-93CE-081726DDC739")
let clockUUID = CBUUID(string: "53E12189-B840-4B21-93CE-081726DDC739")

struct LiloError: LocalizedError {
    let errorDescription: String?
    init(_ message: String.LocalizationValue) { errorDescription = String(localized: message) }
}

@MainActor
final class Lilo: NSObject, ObservableObject {
    @Published var light = 3
    @Published var start = Lilo.date(9, 0)
    @Published var end = Lilo.date(23, 0)
    @Published var status = String(localized: "Searching for LILO…")
    @Published var busy = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    // Every Bluetooth step is sequential: one pending callback at a time.
    private var waiter: CheckedContinuation<Void, Error>?
    private var step = ""
    private var waitID = 0
    private var knownID: UUID? {
        get { UserDefaults.standard.string(forKey: "peripheral").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "peripheral") }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    static func date(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    static func hourMinute(_ date: Date) -> [UInt8] {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return [UInt8(c.hour!), UInt8(c.minute!)]
    }

    func read() async {
        await session(sent: false) {}
    }

    func send() async {
        await session(sent: true) {
            try await self.write(lightUUID, [UInt8(self.light)])
            try await self.write(timeUUID, Lilo.hourMinute(self.start) + Lilo.hourMinute(self.end))
        }
    }

    // Connects, syncs the clock (like the official app), runs the writes, reads back, disconnects.
    private func session(sent: Bool, _ writes: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await connect()
            try await write(clockUUID, Lilo.hourMinute(Date()))
            try await writes()
            try await readBack()
            let time = Date().formatted(date: .omitted, time: .shortened)
            status = sent ? String(localized: "Sent at \(time).") : String(localized: "Read at \(time).")
        } catch {
            status = error.localizedDescription
        }
        if central.isScanning { central.stopScan() }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
    }

    private func readBack() async throws {
        let light = try await read(lightUUID)
        let time = try await read(timeUUID)
        guard light.count == 1, light[0] < lightNames.count, time.count == 4 else {
            throw LiloError("LILO not configured (light \(hex(light)), window \(hex(time))): choose settings and send.")
        }
        self.light = Int(light[0])
        start = Lilo.date(Int(time[0]), Int(time[1]))
        end = Lilo.date(Int(time[2]), Int(time[3]))
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // The LILO advertises irregularly (seen from 1 to 30+ s), so finding and connecting get longer.
    private func wait(_ step: String, timeout: Duration? = .seconds(10), _ start: () -> Void) async throws {
        self.step = step
        waitID += 1
        let id = waitID
        FileHandle.standardError.write(Data("\(Date()) \(step)\n".utf8))
        if let timeout {
            Task {
                try? await Task.sleep(for: timeout)
                guard self.waitID == id else { return }
                self.resume(LiloError(step == "scan" ? "LILO not found." : "LILO not responding (\(step))."))
            }
        }
        try await withCheckedThrowingContinuation { waiter = $0; start() }
    }

    private func resume(_ error: Error? = nil) {
        guard let waiter else { return }
        self.waiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    private func connect() async throws {
        status = String(localized: "Searching for LILO…")
        if central.state == .unknown || central.state == .resetting {
            // No timeout: macOS may be showing the Bluetooth permission prompt.
            try await wait("bluetooth", timeout: nil) {}
        }
        if let error = stateError(central.state) { throw error }
        // Once found, connect by identifier: no need to wait for an advertisement carrying the name.
        if let knownID, let known = central.retrievePeripherals(withIdentifiers: [knownID]).first {
            peripheral = known
            known.delegate = self
        } else {
            // Duplicates on: the name may only arrive in a later packet (scan response).
            try await wait("scan", timeout: .seconds(60)) {
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
        }
        status = String(localized: "Connecting…")
        do {
            try await wait("connect", timeout: .seconds(60)) { central.connect(peripheral!) }
        } catch {
            knownID = nil  // stale identifier (other device?): scan again next time
            throw error
        }
        knownID = peripheral!.identifier
        try await wait("services") { peripheral!.discoverServices([serviceUUID, clockServiceUUID]) }
        for service in peripheral!.services ?? [] {
            try await wait("characteristics") { peripheral!.discoverCharacteristics(nil, for: service) }
        }
        characteristics = Dictionary(
            (peripheral!.services ?? []).flatMap { $0.characteristics ?? [] }.map { ($0.uuid, $0) },
            uniquingKeysWith: { a, _ in a })
        guard [lightUUID, timeUUID, clockUUID].allSatisfy({ characteristics[$0] != nil }) else {
            throw LiloError("LILO light/time/clock characteristics not found (unsupported firmware?)")
        }
    }

    private func stateError(_ state: CBManagerState) -> Error? {
        switch state {
        case .poweredOn: nil
        case .unauthorized: LiloError("Bluetooth access denied: allow LILO in System Settings → Privacy & Security → Bluetooth.")
        case .poweredOff: LiloError("Bluetooth is off.")
        default: LiloError("Bluetooth unavailable.")
        }
    }

    private func read(_ uuid: CBUUID) async throws -> Data {
        let c = characteristics[uuid]!
        try await wait("read \(uuid)") { peripheral!.readValue(for: c) }
        return c.value ?? Data()
    }

    private func write(_ uuid: CBUUID, _ bytes: [UInt8]) async throws {
        let c = characteristics[uuid]!
        try await wait("write \(uuid)") { peripheral!.writeValue(Data(bytes), for: c, type: .withResponse) }
    }
}

extension Lilo: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state != .unknown && central.state != .resetting { resume() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        MainActor.assumeIsolated {
            guard step == "scan", waiter != nil,
                  (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name) == "LILO" else { return }
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            resume()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { resume() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { resume(error ?? LiloError("Connection failed.")) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { resume(LiloError("LILO disconnected.")) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { resume(error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { resume(error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { resume(error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { resume(error) }
    }
}

struct ContentView: View {
    @StateObject private var lilo = Lilo()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Mode", selection: $lilo.light) {
                        ForEach(lightNames.indices, id: \.self) { Text(lightNames[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Light")
                } footer: {
                    Text(lightDescriptions[lilo.light])
                }
                Section {
                    DatePicker("Lights on", selection: $lilo.start, displayedComponents: .hourAndMinute)
                    DatePicker("Lights off", selection: $lilo.end, displayedComponents: .hourAndMinute)
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(lightDuration)
                }
                Section {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            if lilo.busy { ProgressView().controlSize(.small) }
                            Text(lilo.status)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .disabled(lilo.busy)

            HStack {
                Spacer()
                Button("Read") { Task { await lilo.read() } }
                Button("Send") { Task { await lilo.send() } }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(lilo.busy)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460, height: 400)
        .task { await lilo.read() }
    }

    private var lightDuration: String {
        let cal = Calendar.current
        let minutes = (cal.component(.hour, from: lilo.end) - cal.component(.hour, from: lilo.start)) * 60
            + cal.component(.minute, from: lilo.end) - cal.component(.minute, from: lilo.start)
        let total = (minutes + 24 * 60) % (24 * 60)
        return total % 60 == 0
            ? String(localized: "\(total / 60) h of light per day")
            : String(localized: "\(total / 60) h \(total % 60) min of light per day")
    }
}

@main
struct LiloApp: App {
    var body: some Scene {
        Window("LILO", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}
