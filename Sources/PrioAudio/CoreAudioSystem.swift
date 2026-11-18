import CoreAudio
import Foundation
import PrioCore

/// CoreAudio implementation of `AudioSystem`.
///
/// It only reads and writes HAL properties and registers property listeners.
/// It never opens an input or output stream, so it needs no microphone
/// permission (R2). All listeners are delivered on the main queue; there is no
/// polling (R9).
@MainActor
public final class CoreAudioSystem: AudioSystem {
    /// Device list, device liveness or stream layout changed.
    public var onDevicesChanged: (() -> Void)?
    /// The system default device for a direction changed.
    public var onDefaultChanged: ((Direction) -> Void)?
    /// The mute state of the default input changed.
    public var onInputMuteChanged: (() -> Void)?

    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var systemRegistrations: [Registration] = []
    private var deviceRegistrations: [AudioObjectID: [Registration]] = [:]
    private var muteRegistrations: [Registration] = []
    private var listening = false

    public init() {}

    // MARK: - AudioSystem

    public func devices() -> [AudioDevice] {
        deviceIDs().compactMap(device(for:))
    }

    public func defaultDevice(_ direction: Direction) -> String? {
        guard let id = defaultDeviceID(direction) else { return nil }
        return Self.string(id, kAudioDevicePropertyDeviceUID)
    }

    @discardableResult
    public func setDefaultDevice(_ direction: Direction, uid: String) -> Bool {
        guard let id = deviceIDs().first(where: { Self.string($0, kAudioDevicePropertyDeviceUID) == uid }) else {
            return false
        }
        var address = Self.address(direction == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value
        )
        return status == noErr
    }

    // MARK: - Mute (F15)

    /// Whether the current default input reports itself muted.
    public func isDefaultInputMuted() -> Bool {
        guard let id = defaultDeviceID(.input) else { return false }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, element)
            if AudioObjectHasProperty(id, &address), let v = Self.uint32(id, &address) {
                return v != 0
            }
        }
        return false
    }

    // MARK: - Listening

    public func startListening() {
        guard !listening else { return }
        listening = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        systemRegistrations = [
            register(system, Self.address(kAudioHardwarePropertyDevices)) { [weak self] in
                self?.refreshDeviceListeners()
                self?.onDevicesChanged?()
            },
            register(system, Self.address(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in
                self?.refreshMuteListener()
                self?.onDefaultChanged?(.input)
                self?.onInputMuteChanged?()
            },
            register(system, Self.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                self?.onDefaultChanged?(.output)
            },
        ].compactMap { $0 }
        refreshDeviceListeners()
        refreshMuteListener()
    }

    public func stopListening() {
        for r in systemRegistrations { unregister(r) }
        for regs in deviceRegistrations.values { regs.forEach(unregister) }
        muteRegistrations.forEach(unregister)
        systemRegistrations = []
        deviceRegistrations = [:]
        muteRegistrations = []
        listening = false
    }

    /// Per-device listeners: liveness and stream layout (a Bluetooth device
    /// becomes usable when it is alive and has streams; F8).
    private func refreshDeviceListeners() {
        let ids = Set(deviceIDs())
        for (id, regs) in deviceRegistrations where !ids.contains(id) {
            regs.forEach(unregister)
            deviceRegistrations[id] = nil
        }
        for id in ids where deviceRegistrations[id] == nil {
            let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
                (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
                (kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
                (kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
                (kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
            ]
            deviceRegistrations[id] = selectors.compactMap { sel, scope in
                register(id, Self.address(sel, scope)) { [weak self] in
                    self?.onDevicesChanged?()
                }
            }
        }
    }

    private func refreshMuteListener() {
        muteRegistrations.forEach(unregister)
        muteRegistrations = []
        guard let id = defaultDeviceID(.input) else { return }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            if let r = register(id, address, { [weak self] in self?.onInputMuteChanged?() }) {
                muteRegistrations.append(r)
            }
            break
        }
    }

    private func register(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ handler: @escaping @MainActor () -> Void
    ) -> Registration? {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // Delivered on the main queue (see below).
            MainActor.assumeIsolated { handler() }
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        guard status == noErr else { return nil }
        return Registration(object: object, address: address, block: block)
    }

    private func unregister(_ r: Registration) {
        var address = r.address
        AudioObjectRemovePropertyListenerBlock(r.object, &address, DispatchQueue.main, r.block)
    }

    // MARK: - Device inspection

    private func deviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func defaultDeviceID(_ direction: Direction) -> AudioDeviceID? {
        var address = Self.address(direction == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice)
        guard let id = Self.uint32(AudioObjectID(kAudioObjectSystemObject), &address), id != kAudioObjectUnknown else {
            return nil
        }
        return id
    }

    private func device(for id: AudioDeviceID) -> AudioDevice? {
        guard let uid = Self.string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
        let name = Self.string(id, kAudioObjectPropertyName) ?? uid
        let transportRaw = Self.uint32(id, kAudioDevicePropertyTransportType) ?? 0
        let transport = Self.transport(transportRaw)
        let hasInput = Self.streamCount(id, kAudioObjectPropertyScopeInput) > 0
        let hasOutput = Self.streamCount(id, kAudioObjectPropertyScopeOutput) > 0
        let canIn = (Self.uint32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) ?? 0) != 0
        let canOut = (Self.uint32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) ?? 0) != 0
        let hidden = (Self.uint32(id, kAudioDevicePropertyIsHidden) ?? 0) != 0
        let alive = (Self.uint32(id, kAudioDevicePropertyDeviceIsAlive) ?? 1) != 0
        var jack = false
        if transport == .builtIn && hasOutput {
            // 'hdpn' = headphones data source on the built-in output.
            jack = Self.uint32(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput) == 0x6864_706E
        }
        return AudioDevice(
            uid: uid, name: name, transport: transport,
            hasInput: hasInput, hasOutput: hasOutput,
            canBeDefaultInput: canIn, canBeDefaultOutput: canOut,
            isHidden: hidden, isAlive: alive, dataSourceIsHeadphones: jack
        )
    }

    static func transport(_ raw: UInt32) -> Transport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmiDisplayPort
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        default: return .other
        }
    }

    // MARK: - Property helpers

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func uint32(_ id: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> UInt32? {
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func uint32(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = Self.address(selector, scope)
        return uint32(id, &address)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func streamCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}
