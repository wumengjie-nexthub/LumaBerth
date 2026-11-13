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

struct AlbumScanTests {
  @Test func parsesThreeStringBounds() throws {
    let window = try #require(parseWindow(["100", "150", "200"]))
    #expect(window.floor == 100)
    #expect(window.previous == 150)
    #expect(window.current == 200)
  }

  @Test func rejectsMalformedBounds() {
    #expect(parseWindow([]) == nil)
    #expect(parseWindow(["1", "2"]) == nil)
    #expect(parseWindow(["a", "b", "c"]) == nil)
  }

  @Test func startingFromNowSkipsExistingPhotos() throws {
    // Opt-in floor and previous generation are the same: only later changes count.
    let window = try #require(parseWindow(["100", "100", "200"]))
    #expect(window.includes(modified: 100) == false)  // already there at opt-in
    #expect(window.includes(modified: 101))
    #expect(window.includes(modified: 200))
    #expect(window.includes(modified: 201) == false)  // beyond this snapshot
    #expect(window.includes(modified: 99) == false)
  }

  @Test func includingExistingAcceptsTheWholeLibrary() throws {
    let window = try #require(parseWindow(["-1", "-1", "200"]))
    #expect(window.includes(modified: 0))
    #expect(window.includes(modified: 1))
    #expect(window.includes(modified: 200))
    #expect(window.includes(modified: 201) == false)
  }

  @Test func unchangedGenerationYieldsNothing() throws {
    let window = try #require(parseWindow(["200", "200", "200"]))
    #expect(window.includes(modified: 200) == false)
  }

  @Test func floorExcludesPreOptInEdits() throws {
    // A photo edited after opt-in must not re-enter through an older floor.
    let window = try #require(parseWindow(["500", "200", "600"]))
    #expect(window.includes(modified: 300) == false)
    #expect(window.includes(modified: 550))
  }

  @Test func millisRoundTripsEpoch() {
    #expect(millis(nil) == 0)
    #expect(millis(Date(timeIntervalSince1970: 1)) == 1000)
  }

  @Test func permissionNamesCoverEveryStatus() {
    #expect(permissionName(.authorized) == "full")
    #expect(permissionName(.limited) == "partial")
    #expect(permissionName(.denied) == "none")
    #expect(permissionName(.notDetermined) == "none")
    #expect(permissionName(.restricted) == "none")
  }

  @Test func emptyLibraryReportsZeroGeneration() {
    // Reading an empty library must not crash; the value is a plain cursor.
    #expect(libraryGeneration() >= 0)
  }
}
