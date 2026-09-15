import CoreAudio

/// The system's output volume, changed in-process.
///
/// `osascript -e "set volume ..."` would also work, but it costs a process
/// launch per press — around twenty milliseconds — and these are buttons you
/// tap three times in a row. CoreAudio answers on the calling thread, so a
/// press lands as fast as it is drawn.
enum SystemVolume {

    /// `'vmvc'` — the virtual master volume, the one the volume keys move.
    /// Spelled out rather than imported: the constant lives in an AudioToolbox
    /// header that does not reach Swift.
    private static let virtualMasterVolume = AudioObjectPropertySelector(0x766d_7663)
    /// `'outp'`
    private static let outputScope = AudioObjectPropertyScope(0x6f75_7470)

    /// Remembered so a device with no mute of its own can still be silenced.
    private static var levelBeforeMute: Float?

    private static var device: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return status == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: outputScope, mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: Volume

    static var level: Float? {
        guard let device else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(virtualMasterVolume)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    @discardableResult
    static func setLevel(_ value: Float) -> Bool {
        guard let device else { return false }
        var addr = address(virtualMasterVolume)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue
        else { return false }
        var clamped = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &clamped
        ) == noErr
    }

    /// One press-worth. Sixteen steps across the range is what the volume keys
    /// give you, so the button moves the same amount the keyboard does.
    static let step: Float = 1.0 / 16

    static func nudge(_ direction: Float) {
        guard let current = level else { return }
        // Nudging off zero is also unmuting: leaving the mute flag set would
        // raise a volume nobody can hear.
        if isMuted { setMuted(false) }
        setLevel(current + direction * step)
    }

    // MARK: Mute

    static var isMuted: Bool {
        guard let device else { return false }
        var addr = address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &addr) {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                return value != 0
            }
        }
        // No mute property: silence is whatever we made it.
        return levelBeforeMute != nil
    }

    static func setMuted(_ muted: Bool) {
        guard let device else { return }
        var addr = address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &addr),
           AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue {
            var value: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(
                device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
            )
            return
        }
        // Not every output offers a mute flag — some USB and virtual devices
        // do not. Drop the level to zero and put it back afterwards, so the
        // button still does what the glyph promises.
        if muted {
            levelBeforeMute = level
            setLevel(0)
        } else if let restore = levelBeforeMute {
            setLevel(restore)
            levelBeforeMute = nil
        }
    }

    static func toggleMute() { setMuted(!isMuted) }
}
