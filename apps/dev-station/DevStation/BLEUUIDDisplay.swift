import Foundation

struct BLEUUIDDisplay {
    static func normalized(_ uuid: String) -> String {
        let trimmed = uuid.replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        if trimmed.count == 4 {
            return "0000\(trimmed)-0000-1000-8000-00805F9B34FB"
        }
        if trimmed.count == 8 {
            return "\(trimmed)-0000-1000-8000-00805F9B34FB"
        }
        if uuid.count == 4 || uuid.count == 8 {
            return normalized(uuid.uppercased())
        }
        return uuid.uppercased()
    }

    static func shortAndNormalized(_ uuid: String) -> String {
        let trimmed = uuid.replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        if trimmed.count == 4 {
            return "0x\(trimmed) → \(normalized(trimmed))"
        }
        if trimmed.count == 8 {
            return "0x\(trimmed) → \(normalized(trimmed))"
        }
        return uuid
    }
}
