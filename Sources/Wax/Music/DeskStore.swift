import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The records that have been played and put down: the pile that builds up on the desk,
/// how many there have been since it was last cleared, and the milestones passed on the way.
@MainActor
final class DeskStore: ObservableObject {
    struct Record: Identifiable, Codable, Equatable {
        let id: UUID
        let title: String
        let artist: String

        /// A number fixed for the life of the record, so it always lies the same way in the pile.
        var seed: UInt64 {
            withUnsafeBytes(of: id.uuid) { $0.loadUnaligned(as: UInt64.self) }
        }
    }

    struct Milestone: Identifiable, Equatable {
        let count: Int
        let name: String
        let cheer: String

        var id: Int { count }
    }

    static let milestones = [
        Milestone(count: 10, name: "Warm-Up Set", cheer: "Ten records down. You're just getting started."),
        Milestone(count: 30, name: "Deep Listener", cheer: "Thirty records. That's a proper listening session."),
        Milestone(count: 50, name: "Crate Digger", cheer: "Fifty records. Half a crate, and still going."),
        Milestone(count: 100, name: "Wall of Sound", cheer: "A hundred records. Legendary."),
    ]

    /// The pile stops growing here, though the count carries on. Taller would topple.
    static let pileLimit = 36
    private static let coverSide = 512

    /// The pile, bottom record first.
    @Published private(set) var records: [Record] = []
    /// Records put down since the desk was last cleared.
    @Published private(set) var count = 0
    /// Milestones reached at least once. Clearing the desk doesn't take them back.
    @Published private(set) var earned: Set<Int> = []
    /// The milestone being celebrated right now, for a few seconds after it's reached.
    @Published private(set) var celebration: Milestone?

    private struct Saved: Codable {
        var records: [Record]
        var count: Int
        var earned: [Int]
    }

    /// Where the pile is kept between launches; nil keeps it in memory only.
    private let folder: URL?
    private var covers: [UUID: CGImage] = [:]
    private var celebrationEnd: Task<Void, Never>?

    init(persists: Bool = true) {
        if persists, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // A test copy run outside the app keeps its pile apart from the real one.
            let home = Bundle.main.bundleIdentifier ?? "Wax-dev"
            folder = support.appendingPathComponent(home).appendingPathComponent("Desk")
        } else {
            folder = nil
        }
        load()
    }

    var nextMilestone: Milestone? {
        Self.milestones.first { $0.count > count }
    }

    // MARK: - Changes

    /// Lays a finished record on the pile. Without artwork it gets a plain printed sleeve.
    func put(title: String, artist: String, artwork: NSImage?) {
        let record = Record(id: UUID(), title: title, artist: artist)
        let source = artwork ?? Self.plainSleeve(title: title, artist: artist)
        guard let cover = Self.square(source) else { return }

        covers[record.id] = cover
        if let url = file(for: record) { Self.write(cover, to: url) }

        records.append(record)
        while records.count > Self.pileLimit {
            forget(records.removeFirst())
        }
        count += 1
        save()

        if let milestone = Self.milestones.first(where: { $0.count == count }) {
            earned.insert(milestone.count)
            save()
            celebrate(milestone)
        }
    }

    func clear() {
        records.forEach(forget)
        records = []
        count = 0
        save()
    }

    func cover(for record: Record) -> CGImage? {
        if let cached = covers[record.id] { return cached }
        guard let url = file(for: record),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        covers[record.id] = image
        return image
    }

    private func celebrate(_ milestone: Milestone) {
        celebrationEnd?.cancel()
        celebration = milestone
        celebrationEnd = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            self?.celebration = nil
        }
    }

    // MARK: - Storage

    private func file(for record: Record) -> URL? {
        folder?.appendingPathComponent("\(record.id.uuidString).jpg")
    }

    private func forget(_ record: Record) {
        covers[record.id] = nil
        if let url = file(for: record) { try? FileManager.default.removeItem(at: url) }
    }

    private func load() {
        guard let folder,
              let data = try? Data(contentsOf: folder.appendingPathComponent("desk.json")),
              let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        // A record whose cover has gone missing would leave a hole in the pile.
        records = saved.records.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0.id.uuidString).jpg").path) }
        count = max(saved.count, records.count)
        earned = Set(saved.earned)
    }

    private func save() {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = Saved(records: records, count: count, earned: earned.sorted())
        try? JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("desk.json"), options: .atomic)
    }

    // MARK: - Covers

    /// A cover cut square and brought down to a size the pile can hold dozens of.
    private static func square(_ image: NSImage) -> CGImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil, width: coverSide, height: coverSide, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        let side = CGFloat(coverSide)
        let scale = max(side / CGFloat(source.width), side / CGFloat(source.height))
        let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        return context.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private static func plainSleeve(title: String, artist: String) -> NSImage {
        let renderer = ImageRenderer(content: PlaceholderCover(title: title, artist: artist, unit: 1).frame(width: 480, height: 480))
        renderer.scale = 1.1
        return renderer.nsImage ?? NSImage(size: NSSize(width: 480, height: 480))
    }

    // MARK: - Development

    /// Fills the pile for a test, cycling through whatever covers are given.
    func debugFill(_ total: Int, covers pictures: [NSImage]) {
        for index in 0..<total {
            let record = Record(id: UUID(), title: "Test \(index + 1)", artist: "Wax")
            let picture = pictures.isEmpty ? Self.plainSleeve(title: record.title, artist: record.artist) : pictures[index % pictures.count]
            guard let cover = Self.square(picture) else { continue }
            covers[record.id] = cover
            records.append(record)
        }
        records = Array(records.suffix(Self.pileLimit))
        count += total
    }

    func debugCelebrate(_ count: Int) {
        guard let milestone = Self.milestones.first(where: { $0.count == count }) else { return }
        earned.insert(milestone.count)
        celebrate(milestone)
    }
}
