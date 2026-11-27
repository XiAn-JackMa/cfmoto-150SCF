// SPDX-License-Identifier: AGPL-3.0-only
//
// User-chosen mapping from the motorcycle's handlebar buttons to CarPlay controls.
//
// Why it is configurable: what this dash sends was measured (see HandlebarProbe), and the useful
// assignment is a matter of taste — how fast a double is, whether a held arrow should repeat or jump
// home, which gesture should select. Nobody can pick that from a desk, so the rider picks it.
//
// Gestures are named for what the bike DOES, not for a key, because the same button produces
// different events depending on how long it is held:
//   arrowShort   ▲/▼ quick press  -> arrives as a volume step (and really moves the volume)
//   arrowLong    ▲/▼ held         -> arrives as a clean previousTrack / nextTrack
//   arrowDouble  ▲/▼ twice quickly-> the firmware merges it into one bigger volume step
//   setLong      SET held         -> arrives as play/pause
//   setShort     SET quick press  -> the dash consumes it; listed so the gap is visible
//   setDouble    SET twice quickly

import Foundation

/// What the bike did.
enum HandlebarGesture: String, CaseIterable, Codable {
    case arrowUpShort
    case arrowUpLong
    case arrowUpDouble
    case arrowDownShort
    case arrowDownLong
    case arrowDownDouble
    case setShort
    case setLong
    case setDouble

    var title: String {
        switch self {
        case .arrowUpShort: return "▲ 单击"
        case .arrowUpLong: return "▲ 长按"
        case .arrowUpDouble: return "▲ 双击"
        case .arrowDownShort: return "▼ 单击"
        case .arrowDownLong: return "▼ 长按"
        case .arrowDownDouble: return "▼ 双击"
        case .setShort: return "SET 单击"
        case .setLong: return "SET 长按"
        case .setDouble: return "SET 双击"
        }
    }

    /// Gestures the dash never delivers, so the row can say so instead of looking broken.
    var isUnavailable: Bool { self == .setShort || self == .setDouble }
}

/// What to send to CarPlay. `none` lets a gesture be switched off without inventing something.
enum HandlebarAction: String, CaseIterable, Codable {
    case none
    case knobPrevious
    case knobNext
    case select
    case back
    case home
    case playPause
    case next
    case previous
    case siri
    case hookSwitch

    var title: String {
        switch self {
        case .none: return "不执行"
        case .knobPrevious: return "上一项（↑）"
        case .knobNext: return "下一项（↓）"
        case .select: return "选择（确认）"
        case .back: return "返回"
        case .home: return "主页"
        case .playPause: return "播放/暂停"
        case .next: return "下一曲"
        case .previous: return "上一曲"
        case .siri: return "Siri"
        case .hookSwitch: return "接听/挂断"
        }
    }

    var control: CarPlayControl? {
        CarPlayControl(rawValue: rawValue)
    }
}

enum HandlebarMapping {
    private static let key = "handlebarMapping"
    private static let timingKey = "handlebarTiming"

    /// Defaults for the non-touch dash: only the four volume-channel gestures are wired, because they
    /// arrive with the phone locked and while music is playing. SET long and ▲▼ long are transport
    /// keys that the music app owns during playback, so they default to `.none` (handed back to the
    /// music) but stay configurable here. Everything can be replaced from 设置 → 车把按键.
    static let defaults: [HandlebarGesture: HandlebarAction] = [
        .arrowUpShort: .knobPrevious,
        .arrowDownShort: .knobNext,
        .arrowUpDouble: .select,
        .arrowDownDouble: .back,
        .arrowUpLong: .none,
        .arrowDownLong: .none,
        .setLong: .none,
        .setShort: .none,
        .setDouble: .none
    ]

    static func action(for gesture: HandlebarGesture) -> HandlebarAction {
        stored()[gesture] ?? defaults[gesture] ?? .none
    }

    static func set(_ action: HandlebarAction, for gesture: HandlebarGesture) {
        var current = stored()
        current[gesture] = action
        save(current)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: timingKey)
    }

    private static func stored() -> [HandlebarGesture: HandlebarAction] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var result: [HandlebarGesture: HandlebarAction] = [:]
        for (gesture, action) in raw {
            guard let g = HandlebarGesture(rawValue: gesture), let a = HandlebarAction(rawValue: action) else { continue }
            result[g] = a
        }
        return result
    }

    private static func save(_ value: [HandlebarGesture: HandlebarAction]) {
        var raw: [String: String] = [:]
        for (gesture, action) in value { raw[gesture.rawValue] = action.rawValue }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - Timing

    /// How long a second press on the same arrow still counts as a double, in seconds. 0.2 s keeps
    /// single presses snappy; a rider who wants a calmer double can raise it from 设置 → 车把按键.
    static var doubleTapWindow: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: timingKey)
            return stored > 0 ? stored : 0.20
        }
        set { UserDefaults.standard.set(newValue, forKey: timingKey) }
    }

    /// Whether a held ▲▼ keeps scrolling instead of moving one step.
    static var repeatsWhenHeld: Bool {
        get {
            if UserDefaults.standard.object(forKey: "handlebarHeldRepeats") == nil { return true }
            return UserDefaults.standard.bool(forKey: "handlebarHeldRepeats")
        }
        set { UserDefaults.standard.set(newValue, forKey: "handlebarHeldRepeats") }
    }
}
