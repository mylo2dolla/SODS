import Foundation
import ScannerSpectrumCore

struct DynamicFieldRow: Identifiable, Hashable {
    let key: String
    let value: String

    var id: String { key }
}

enum DynamicFieldRenderer {
    private static let sensitiveTokens = [
        "password",
        "pass",
        "secret",
        "token",
        "api_key",
        "apikey",
        "auth",
        "credential",
        "private_key"
    ]

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    static func rows(fromJSON object: [String: JSONValue]) -> [DynamicFieldRow] {
        var rowsByKey: [String: String] = [:]
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            flattenJSONValue(value, keyPath: key, into: &rowsByKey)
        }
        return sortedRows(from: rowsByKey)
    }

    static func rows(fromObject object: Any) -> [DynamicFieldRow] {
        var rowsByKey: [String: String] = [:]
        flattenAny(object, keyPath: nil, into: &rowsByKey)
        return sortedRows(from: rowsByKey)
    }

    private static func sortedRows(from rowsByKey: [String: String]) -> [DynamicFieldRow] {
        rowsByKey
            .keys
            .sorted()
            .compactMap { key in
                guard let value = rowsByKey[key], !value.isEmpty else { return nil }
                return DynamicFieldRow(key: key, value: value)
            }
    }

    private static func flattenJSONValue(_ value: JSONValue, keyPath: String, into rowsByKey: inout [String: String]) {
        switch value {
        case .string(let raw):
            insert(raw, for: keyPath, into: &rowsByKey)
        case .number(let raw):
            insert(formattedNumber(raw), for: keyPath, into: &rowsByKey)
        case .bool(let raw):
            insert(raw ? "true" : "false", for: keyPath, into: &rowsByKey)
        case .array(let values):
            for (index, entry) in values.enumerated() {
                flattenJSONValue(entry, keyPath: "\(keyPath)[\(index)]", into: &rowsByKey)
            }
        case .object(let object):
            for key in object.keys.sorted() {
                guard let nestedValue = object[key] else { continue }
                flattenJSONValue(nestedValue, keyPath: "\(keyPath).\(key)", into: &rowsByKey)
            }
        case .null:
            return
        }
    }

    private static func flattenAny(_ value: Any, keyPath: String?, into rowsByKey: inout [String: String]) {
        guard let unwrapped = unwrapOptional(value) else { return }

        let resolvedKey = keyPath ?? "value"

        if let json = unwrapped as? JSONValue {
            flattenJSONValue(json, keyPath: resolvedKey, into: &rowsByKey)
            return
        }
        if let jsonObject = unwrapped as? [String: JSONValue] {
            for key in jsonObject.keys.sorted() {
                guard let nestedValue = jsonObject[key] else { continue }
                flattenJSONValue(nestedValue, keyPath: keyPathJoin(keyPath, key), into: &rowsByKey)
            }
            return
        }
        if let raw = unwrapped as? String {
            insert(raw, for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Bool {
            insert(raw ? "true" : "false", for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Int {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Int8 {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Int16 {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Int32 {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Int64 {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? UInt {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? UInt8 {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? UInt16 {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? UInt32 {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? UInt64 {
            insert(String(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Double {
            insert(formattedNumber(raw), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Float {
            insert(formattedNumber(Double(raw)), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Date {
            insert(raw.formatted(date: .abbreviated, time: .standard), for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? UUID {
            insert(raw.uuidString, for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? URL {
            insert(raw.absoluteString, for: resolvedKey, into: &rowsByKey)
            return
        }
        if let raw = unwrapped as? Data {
            insert(raw.map { String(format: "%02X", $0) }.joined(), for: resolvedKey, into: &rowsByKey)
            return
        }

        let mirror = Mirror(reflecting: unwrapped)
        switch mirror.displayStyle {
        case .collection, .set:
            for (index, child) in mirror.children.enumerated() {
                flattenAny(child.value, keyPath: "\(resolvedKey)[\(index)]", into: &rowsByKey)
            }
        case .dictionary:
            var entries: [(String, Any)] = []
            for child in mirror.children {
                let pairMirror = Mirror(reflecting: child.value)
                let parts = Array(pairMirror.children)
                guard parts.count == 2 else { continue }
                let keyText = dictionaryKeyString(parts[0].value)
                entries.append((keyText, parts[1].value))
            }
            for (key, entryValue) in entries.sorted(by: { $0.0 < $1.0 }) {
                flattenAny(entryValue, keyPath: keyPathJoin(keyPath, key), into: &rowsByKey)
            }
        case .enum:
            if mirror.children.isEmpty {
                insert(String(describing: unwrapped), for: resolvedKey, into: &rowsByKey)
            } else {
                for child in mirror.children {
                    let label = child.label ?? "value"
                    flattenAny(child.value, keyPath: keyPathJoin(keyPath, label), into: &rowsByKey)
                }
            }
        default:
            let children = mirror.children
                .compactMap { child -> (String, Any)? in
                    guard let label = child.label else { return nil }
                    return (label, child.value)
                }
                .sorted(by: { $0.0 < $1.0 })

            if children.isEmpty {
                insert(String(describing: unwrapped), for: resolvedKey, into: &rowsByKey)
            } else {
                for (label, childValue) in children {
                    flattenAny(childValue, keyPath: keyPathJoin(keyPath, label), into: &rowsByKey)
                }
            }
        }
    }

    private static func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }

    private static func dictionaryKeyString(_ key: Any) -> String {
        if let stringKey = key as? String {
            return stringKey
        }
        if let uuidKey = key as? UUID {
            return uuidKey.uuidString
        }
        return String(describing: key)
    }

    private static func keyPathJoin(_ prefix: String?, _ key: String) -> String {
        guard let prefix, !prefix.isEmpty else {
            return key
        }
        return "\(prefix).\(key)"
    }

    private static func insert(_ rawValue: String, for keyPath: String, into rowsByKey: inout [String: String]) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rowsByKey[keyPath] = maskIfSensitive(trimmed, keyPath: keyPath)
    }

    private static func maskIfSensitive(_ rawValue: String, keyPath: String) -> String {
        guard isSensitive(keyPath) else {
            return rawValue
        }

        let count = rawValue.count
        if count <= 6 {
            return "••••"
        }

        let prefixCount = min(2, max(1, count / 8))
        let suffixCount = min(2, max(1, count / 8))

        if count <= (prefixCount + suffixCount + 2) {
            return "••••"
        }

        let prefix = rawValue.prefix(prefixCount)
        let suffix = rawValue.suffix(suffixCount)
        return "\(prefix)••••\(suffix)"
    }

    private static func isSensitive(_ keyPath: String) -> Bool {
        let lowercase = keyPath.lowercased()
        let segments = lowercase.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        for segment in segments {
            for token in sensitiveTokens where segment.contains(token) {
                return true
            }
        }
        return false
    }

    private static func formattedNumber(_ value: Double) -> String {
        if value.isNaN || value.isInfinite {
            return String(value)
        }
        if let formatted = numberFormatter.string(from: NSNumber(value: value)) {
            return formatted
        }
        return String(value)
    }
}
