//
//  Formatting.swift
//  Comprimio
//

import Foundation

enum Fmt {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: value)
    }

    static func pixels(_ size: CGSize?) -> String {
        guard let size, size.width > 0 else { return "—" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    static func percent(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return String(format: "%+.1f%%", -ratio * 100)
    }
}
