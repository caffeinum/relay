import AppKit
import CryptoKit
import ImageIO
import RelayCore

/// Avatars as CGImages for a layer's contents: initials on one of 8 hashed
/// tones right away, the photo once it's decoded off main (memory LRU of
/// 512, disk cache under support/avatars). `onLoad(id)` says when to redraw.
final class Avatars {
    static let shared = Avatars()
    var onLoad: ((String) -> Void)?

    private static let tones: [UInt32] = [0x4A6FA5, 0x8E5572, 0x5B8C5A, 0xA0703A, 0x6B5B95, 0x3E8A8A, 0x9A5B4E, 0x5F6B7A]
    private var placeholders: [String: CGImage] = [:]
    private var photos: [String: CGImage] = [:]
    private var order: [String] = []
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    private let queue = DispatchQueue(label: "\(Brand.bundleID).avatars", qos: .utility, attributes: .concurrent)
    private let limit = 512

    func layerContents(for id: String, name: String, url: String?, size: CGFloat, scale: CGFloat = 2) -> CGImage {
        if let url {
            let key = "\(id)|\(url)"
            if let p = photos[key] { touch(key); return p }
            load(id: id, url: url, key: key)
        }
        return placeholder(id: id, name: name, size: size, scale: scale)
    }

    private func touch(_ key: String) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }

    static func initials(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }.filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    private func placeholder(id: String, name: String, size: CGFloat, scale: CGFloat) -> CGImage {
        let key = "\(id)|\(name)|\(size)|\(scale)"
        if let p = placeholders[key] { return p }
        let px = Int(size * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let tone = Self.tones[Int(h % UInt32(Self.tones.count))]
        ctx.setFillColor(CGColor(srgbRed: CGFloat((tone >> 16) & 0xFF) / 255, green: CGFloat((tone >> 8) & 0xFF) / 255, blue: CGFloat(tone & 0xFF) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let text = Self.initials(name.isEmpty ? id : name)
        let font = NSFont.systemFont(ofSize: size * 0.42, weight: .semibold)
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(s)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: (size - bounds.width) / 2 - bounds.minX, y: (size - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, ctx)
        let img = ctx.makeImage()!
        placeholders[key] = img
        return img
    }

    private func diskPath(_ id: String, _ url: String) -> URL {
        let hash = SHA256.hash(data: Data(url.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return Paths.support.appendingPathComponent("avatars/\(id)-\(hash).png")
    }

    private func load(id: String, url: String, key: String) {
        guard !loading.contains(key), !failed.contains(key) else { return }
        guard let remote = URL(string: url) else {
            failed.insert(key)
            log("avatar \(id): bad url \(url)")
            return
        }
        loading.insert(key)
        let path = diskPath(id, url)
        queue.async { [weak self] in
            let data: Data
            do {
                if let d = try? Data(contentsOf: path) { data = d } else {
                    data = try Data(contentsOf: remote)
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: path, options: .atomic)
                }
            } catch {
                DispatchQueue.main.async { self?.finish(id: id, key: key, image: nil, error: "\(error)") }
                return
            }
            let opts = [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 96] as CFDictionary
            let img = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, opts) }
            DispatchQueue.main.async { self?.finish(id: id, key: key, image: img, error: img == nil ? "can't decode \(data.count) bytes" : nil) }
        }
    }

    private func finish(id: String, key: String, image: CGImage?, error: String?) {
        loading.remove(key)
        guard let image else {
            failed.insert(key)
            log("avatar \(id): \(error ?? "no image")")
            return
        }
        photos[key] = image
        touch(key)
        while order.count > limit { photos[order.removeFirst()] = nil }
        onLoad?(id)
    }
}
