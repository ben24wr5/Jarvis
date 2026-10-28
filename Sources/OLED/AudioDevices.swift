import Foundation
import CoreAudio
import AudioToolbox

/// Finds the Mac's microphones. By default OLED listens through AirPods when they're in; this is an
/// optional setting to use the Mac's built-in microphone instead (keeps AirPods' sound in high quality).
enum AudioDevices {
    static let preferBuiltInKey = "preferBuiltInMic"

    /// Off by default: with AirPods (or any Bluetooth headset) connected, OLED listens through them.
    static var preferBuiltInWithBluetooth: Bool {
        get { UserDefaults.standard.object(forKey: preferBuiltInKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: preferBuiltInKey) }
    }

    static var defaultInputDevice: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func transportType(of device: AudioDeviceID) -> UInt32 {
        var type = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type)
        return type
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let t = transportType(of: device)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static var allDevices: [AudioDeviceID] {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// The Mac's own microphone (MacBook/iMac built-in), if it has one.
    static var builtInMicrophone: AudioDeviceID? {
        allDevices.first { transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    /// The microphone OLED should listen with right now, or nil to use the Mac's default.
    static var microphoneToUse: AudioDeviceID? {
        guard preferBuiltInWithBluetooth,
              let current = defaultInputDevice, isBluetooth(current),
              let builtIn = builtInMicrophone else { return nil }
        return builtIn
    }

    /// Points an audio unit (the engine's input) at a specific microphone.
    @discardableResult
    static func use(_ device: AudioDeviceID, on unit: AudioUnit) -> Bool {
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr
    }
}
