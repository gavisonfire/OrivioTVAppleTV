//
//  KSColorProbe.swift
//  KSPlayer
//
//  Orivio diagnostics. Not upstream.
//

import CoreVideo
import Foundation

/// A one-line-per-fact trace of the colour pipeline, from the stream's own
/// tags through to the matrix the shader actually multiplies by.
///
/// Colour state is per-FORMAT, not per-frame, so every probe fires through
/// `once(_:_:)` — keyed, de-duplicated, and reset at the start of each load.
/// Without that, the per-frame sites (the render path, the conversion matrix)
/// would emit 24–60 lines a second and bury everything else.
///
/// The sink is set by the app (PlayerViewModel), which appends to the same
/// UserDefaults trail as the DV diagnostics so the lines survive the session
/// and can be pulled off the device afterwards.
public enum KSColorProbe {
    /// Where probe lines go. Nil (the default) makes every probe a no-op, so
    /// this costs nothing when nobody is listening.
    public static var sink: ((String) -> Void)?

    private static let lock = NSLock()
    private static var seen = Set<String>()

    /// Forget every key — call at the start of a load so the next session
    /// re-emits the whole picture.
    public static func reset() {
        lock.lock()
        seen.removeAll()
        lock.unlock()
    }

    /// Emit `line` the first time `key` is seen since the last `reset()`.
    public static func once(_ key: String, _ line: () -> String) {
        guard sink != nil else { return }
        lock.lock()
        let isNew = seen.insert(key).inserted
        lock.unlock()
        guard isNew else { return }
        sink?(line())
    }
}

/// Short name for a CoreVideo colour tag — `nil` is the interesting case, so
/// it gets said out loud rather than rendered as an empty string.
func ksProbeTag(_ tag: CFString?) -> String {
    guard let tag else { return "nil" }
    return (tag as String)
        .replacingOccurrences(of: "ITU_R_", with: "BT.")
        .replacingOccurrences(of: "SMPTE_ST_", with: "SMPTE")
}

/// FourCC rendering for an OSType, so pixel formats read as `420v` / `420f`
/// / `x420` rather than as a meaningless integer.
func ksProbeFourCC(_ type: OSType?) -> String {
    guard let type else { return "nil" }
    let bytes = [UInt8(truncatingIfNeeded: type >> 24), UInt8(truncatingIfNeeded: type >> 16),
                 UInt8(truncatingIfNeeded: type >> 8), UInt8(truncatingIfNeeded: type)]
    let scalars = bytes.map { (0x20 ... 0x7E).contains($0) ? Character(UnicodeScalar($0)) : "?" }
    return String(scalars)
}
