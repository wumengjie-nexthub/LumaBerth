import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import lumaberth

struct MediaChannelTests {
  private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("media-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func writeImage(
    _ url: URL, width: Int, height: Int, orientation: Int?, dateTaken: String?
  ) throws {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    var properties: [CFString: Any] = [:]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    if let dateTaken {
      properties[kCGImagePropertyExifDictionary] = [
        kCGImagePropertyExifDateTimeOriginal: dateTaken
      ]
    }
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
  }

  @Test func thumbnailScalesOrientsAndReadsDate() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.jpg")
    let thumb = dir.appendingPathComponent("thumb.jpg")
    try writeImage(
      source, width: 1000, height: 600, orientation: 6,
      dateTaken: "2026:11:12 08:30:00")

    let taken = try MakeThumbnail(
      source: source.path, thumb: thumb.path, metadata: source.path)

    #expect(FileManager.default.fileExists(atPath: thumb.path))
    let thumbSource = CGImageSourceCreateWithURL(thumb as CFURL, nil)!
    let decoded = CGImageSourceCreateThumbnailAtIndex(
      thumbSource, 0,
      [kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary)!
    #expect(max(decoded.width, decoded.height) <= 480)
    // Orientation 6 rotates the landscape source into portrait.
    #expect(decoded.height > decoded.width)

    var components = DateComponents()
    components.year = 2026
    components.month = 11
    components.day = 12
    components.hour = 8
    components.minute = 30
    let expected = Calendar.current.date(from: components)!
    #expect(taken?.int64Value == Int64(expected.timeIntervalSince1970 * 1000))
  }

  @Test func noExifDateReturnsNil() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("plain.jpg")
    let thumb = dir.appendingPathComponent("thumb.jpg")
    try writeImage(source, width: 800, height: 800, orientation: nil, dateTaken: nil)
    let taken = try MakeThumbnail(
      source: source.path, thumb: thumb.path, metadata: source.path)
    #expect(taken == nil)
    #expect(FileManager.default.fileExists(atPath: thumb.path))
  }

  @Test func smallImageIsNotUpscaled() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("small.jpg")
    let thumb = dir.appendingPathComponent("thumb.jpg")
    try writeImage(source, width: 200, height: 100, orientation: nil, dateTaken: nil)
    _ = try MakeThumbnail(source: source.path, thumb: thumb.path, metadata: source.path)
    let thumbSource = CGImageSourceCreateWithURL(thumb as CFURL, nil)!
    let decoded = CGImageSourceCreateThumbnailAtIndex(
      thumbSource, 0,
      [kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary)!
    #expect(decoded.width == 200)
    #expect(decoded.height == 100)
  }

  @Test func unreadableSourceThrows() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let missing = dir.appendingPathComponent("missing.jpg")
    let thumb = dir.appendingPathComponent("thumb.jpg")
    #expect(throws: ThumbnailError.self) {
      try MakeThumbnail(source: missing.path, thumb: thumb.path, metadata: missing.path)
    }
  }
}
