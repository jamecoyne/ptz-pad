import Foundation

/// Raw VISCA command builders and reply parsing.
/// The FoMaKo / Minrray camera speaks plain VISCA frames over UDP (no Sony IP header).
enum Visca {
    enum PanDir: UInt8 { case left = 0x01, right = 0x02, stop = 0x03 }
    enum TiltDir: UInt8 { case up = 0x01, down = 0x02, stop = 0x03 }

    static let maxPanSpeed = 24
    static let maxTiltSpeed = 20
    static let maxZoomSpeed = 7

    static func panTiltDrive(panSpeed: Int, tiltSpeed: Int, pan: PanDir, tilt: TiltDir) -> [UInt8] {
        let v = UInt8(min(max(panSpeed, 1), maxPanSpeed))
        let w = UInt8(min(max(tiltSpeed, 1), maxTiltSpeed))
        return [0x81, 0x01, 0x06, 0x01, v, w, pan.rawValue, tilt.rawValue, 0xFF]
    }

    static let panTiltStop: [UInt8] = [0x81, 0x01, 0x06, 0x01, 0x08, 0x08, 0x03, 0x03, 0xFF]
    static let home: [UInt8] = [0x81, 0x01, 0x06, 0x04, 0xFF]

    static func absolutePosition(pan: Int, tilt: Int, panSpeed: Int = 14, tiltSpeed: Int = 14) -> [UInt8] {
        let p = UInt16(truncatingIfNeeded: pan)
        let t = UInt16(truncatingIfNeeded: tilt)
        return [0x81, 0x01, 0x06, 0x02,
                UInt8(min(max(panSpeed, 1), maxPanSpeed)), UInt8(min(max(tiltSpeed, 1), maxTiltSpeed)),
                UInt8((p >> 12) & 0xF), UInt8((p >> 8) & 0xF), UInt8((p >> 4) & 0xF), UInt8(p & 0xF),
                UInt8((t >> 12) & 0xF), UInt8((t >> 8) & 0xF), UInt8((t >> 4) & 0xF), UInt8(t & 0xF),
                0xFF]
    }

    /// signedSpeed > 0 zooms in (tele), < 0 zooms out (wide), 0 stops.
    static func zoom(_ signedSpeed: Int) -> [UInt8] {
        let s = UInt8(min(abs(signedSpeed), maxZoomSpeed))
        let p: UInt8 = signedSpeed > 0 ? (0x20 | s) : (signedSpeed < 0 ? (0x30 | s) : 0x00)
        return [0x81, 0x01, 0x04, 0x07, p, 0xFF]
    }

    static let zoomStop: [UInt8] = [0x81, 0x01, 0x04, 0x07, 0x00, 0xFF]
    static let focusOnePush: [UInt8] = [0x81, 0x01, 0x04, 0x18, 0x01, 0xFF]
    static let focusAuto: [UInt8] = [0x81, 0x01, 0x04, 0x38, 0x02, 0xFF]

    static func presetRecall(_ n: Int) -> [UInt8] { [0x81, 0x01, 0x04, 0x3F, 0x02, UInt8(n & 0x7F), 0xFF] }
    static func presetSet(_ n: Int) -> [UInt8] { [0x81, 0x01, 0x04, 0x3F, 0x01, UInt8(n & 0x7F), 0xFF] }

    static let panTiltPosInq: [UInt8] = [0x81, 0x09, 0x06, 0x12, 0xFF]
    static let zoomPosInq: [UInt8] = [0x81, 0x09, 0x04, 0x47, 0xFF]

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Split a datagram that may contain several 0xFF-terminated frames.
    static func split(_ d: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var cur: [UInt8] = []
        for b in d {
            cur.append(b)
            if b == 0xFF { out.append(cur); cur = [] }
        }
        return out
    }

    static func parse(_ d: [UInt8]) -> ViscaReply {
        guard d.count >= 3, d.last == 0xFF else { return .unknown(d) }
        switch d[1] & 0xF0 {
        case 0x40:
            return .ack
        case 0x50:
            switch d.count {
            case 3: return .completion
            case 11: return .panTilt(pan: signed16(nibbles(d, from: 2)), tilt: signed16(nibbles(d, from: 6)))
            case 7: return .zoom(Int(nibbles(d, from: 2)))
            default: return .unknown(d)
            }
        case 0x60:
            return .error(d.count > 3 ? d[2] : 0)
        default:
            return .unknown(d)
        }
    }

    private static func nibbles(_ d: [UInt8], from i: Int) -> UInt16 {
        (UInt16(d[i] & 0xF) << 12) | (UInt16(d[i + 1] & 0xF) << 8) | (UInt16(d[i + 2] & 0xF) << 4) | UInt16(d[i + 3] & 0xF)
    }

    private static func signed16(_ v: UInt16) -> Int { Int(Int16(bitPattern: v)) }
}

enum ViscaReply {
    case ack
    case completion
    case error(UInt8)
    case panTilt(pan: Int, tilt: Int)
    case zoom(Int)
    case unknown([UInt8])

    var description: String {
        switch self {
        case .ack: return "ACK"
        case .completion: return "completion"
        case .error(let c):
            switch c {
            case 0x02: return "error: syntax"
            case 0x03: return "error: command buffer full"
            case 0x04: return "error: cancelled"
            case 0x05: return "error: no socket"
            case 0x41: return "error: not executable"
            default: return String(format: "error 0x%02X", c)
            }
        case .panTilt(let p, let t): return "pan=\(p) tilt=\(t)"
        case .zoom(let z): return "zoom=\(z)"
        case .unknown(let b): return "unknown \(Visca.hex(b))"
        }
    }
}
