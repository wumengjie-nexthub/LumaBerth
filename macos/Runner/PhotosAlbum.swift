import FlutterMacOS
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// The Photos library is exposed as a single virtual volume, mirroring the
/// volume map Android builds from MediaStore. The cursor generation is the
/// newest asset modification time in milliseconds, so "photos after opt-in"
/// behaves like MediaStore's generation counters.
let albumVolume = "photos"
/// Bumped only if the cursor layout changes. Android uses MediaStore's library
/// version here so a rebuilt database forces the user to re-pick a start point.
let albumVersion = "photos"

struct AlbumScanWindow {
  let floor: Int64
  let previous: Int64
  let current: Int64

  /// MediaStore excludes rows added before the opt-in floor and rows untouched
  /// since the previous generation. macOS has no separate "added" counter, so
  /// both tests use the modification time: a newly imported photo gets a fresh
  /// modification date, while re-editing one already backed up is ignored by
  /// the queue's UNIQUE(target, source) key.
  func includes(modified: Int64) -> Bool {
    modified > max(floor, previous) && modified <= current
  }
}

func parseWindow(_ bounds: [String]) -> AlbumScanWindow? {
  guard bounds.count == 3,
    let floor = Int64(bounds[0]),
    let previous = Int64(bounds[1]),
    let current = Int64(bounds[2])
  else { return nil }
  return AlbumScanWindow(floor: floor, previous: previous, current: current)
}

func millis(_ date: Date?) -> Int64 {
  guard let date else { return 0 }
  return Int64((date.timeIntervalSince1970 * 1000).rounded())
}

func permissionName(_ status: PHAuthorizationStatus) -> String {
  switch status {
  case .authorized: return "full"
  case .limited: return "partial"
  default: return "none"
  }
}

/// The asset resource holding the untouched original, preferring it over an
/// edited full-size render.
func originalResource(of asset: PHAsset) -> PHAssetResource? {
  let resources = PHAssetResource.assetResources(for: asset)
  return resources.first { $0.type == .photo } ?? resources.first
}

/// fileSize is not part of the public PHAssetResource API; it is the same key
/// Apple documents for uploads and is only used to preview the album size. The
/// real byte count is always measured from the exported file.
func resourceSize(_ resource: PHAssetResource?) -> Int64 {
  guard let value = resource?.value(forKey: "fileSize") as? NSNumber else {
    return 0
  }
  return value.int64Value
}

func albumRow(for asset: PHAsset) -> [String: Any?] {
  let resource = originalResource(of: asset)
  return [
    "source": asset.localIdentifier,
    "name": resource?.originalFilename ?? (asset.localIdentifier + ".jpg"),
    "size": resourceSize(resource),
    "time": millis(asset.creationDate ?? asset.modificationDate),
  ]
}

/// Newest modification time in the library, or 0 when it holds no photos.
func libraryGeneration() -> Int64 {
  let options = PHFetchOptions()
  options.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
  options.fetchLimit = 1
  options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
  guard let asset = PHAsset.fetchAssets(with: options).firstObject else { return 0 }
  return millis(asset.modificationDate ?? asset.creationDate)
}

func albumSnapshot() -> [String: Any] {
  [albumVolume: ["version": albumVersion, "generation": libraryGeneration()]]
}

func albumScan(windows: [String: [String]]) throws -> [[String: Any?]] {
  guard let bounds = windows[albumVolume], let window = parseWindow(bounds) else {
    return []
  }
  var rows: [[String: Any?]] = []
  let options = PHFetchOptions()
  options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
  options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
  PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
    let modified = millis(asset.modificationDate ?? asset.creationDate)
    if window.includes(modified: modified) { rows.append(albumRow(for: asset)) }
  }
  return rows
}

/// Appends an album diagnostic line to a file inside the app container, where
/// it can be read without attaching a debugger.
func albumDiagnostic(_ text: String) {
  guard
    let dir = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
  else { return }
  let url = dir.appendingPathComponent("album-diagnostics.log")
  // Keep the file small; it only exists to explain a failed backup.
  if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
    size > 64 * 1024 {
    try? FileManager.default.removeItem(at: url)
  }
  let line = Data((text + "\n").utf8)
  if let handle = try? FileHandle(forWritingTo: url) {
    handle.seekToEndOfFile()
    handle.write(line)
    try? handle.close()
  } else {
    try? line.write(to: url)
  }
}

/// Resolves an asset by identifier.
///
/// `PHAsset.fetchAssets(withLocalIdentifiers:)` misses some sources that the
/// global fetch returns (shared albums and synced items on macOS), so fall back
/// to an enumeration and match the identifier ourselves.
func findAsset(_ identifier: String) -> PHAsset? {
  let direct = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
  if let asset = direct.firstObject { return asset }
  let options = PHFetchOptions()
  options.includeHiddenAssets = true
  options.includeAllBurstAssets = true
  var match: PHAsset?
  PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, stop in
    if asset.localIdentifier == identifier {
      match = asset
      stop.pointee = true
    }
  }
  let status = PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
  if let match {
    albumDiagnostic("SCAN \(identifier) sourceType=\(match.sourceType.rawValue) auth=\(status)")
  } else {
    let imageOptions = PHFetchOptions()
    imageOptions.predicate = NSPredicate(
      format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    albumDiagnostic(
      "MISS \(identifier) auth=\(status) direct=\(direct.count) "
        + "all=\(PHAsset.fetchAssets(with: nil).count) "
        + "images=\(PHAsset.fetchAssets(with: imageOptions).count)")
  }
  return match
}

/// The message a user can act on when an asset cannot be resolved. Losing the
/// Photos grant is by far the most common cause, and "原片已移除" would send the
/// user looking for a photo that is still there.
func unresolvableAssetError() -> AlbumError {
  if PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized {
    return AlbumError.missing("需要「照片」权限才能继续备份，请在系统设置中允许映格访问照片")
  }
  return AlbumError.missing("这张照片已不在系统相册中")
}

func albumMetadata(identifier: String) throws -> [String: Any?] {
  guard let asset = findAsset(identifier) else {
    throw unresolvableAssetError()
  }
  return albumRow(for: asset)
}

/// Exports the original through PhotoKit and renders the 480px thumbnail with
/// ImageIO, returning the EXIF capture time in milliseconds.
func albumPrepare(identifier: String, original: String, thumb: String) throws -> NSNumber? {
  guard let asset = findAsset(identifier) else {
    throw unresolvableAssetError()
  }
  guard let resource = originalResource(of: asset) else {
    throw AlbumError.missing("无法读取这张照片的原件")
  }
  let url = URL(fileURLWithPath: original)
  try? FileManager.default.removeItem(at: url)
  let options = PHAssetResourceRequestOptions()
  // iCloud originals may not be downloaded to this Mac yet.
  options.isNetworkAccessAllowed = true
  let done = DispatchSemaphore(value: 0)
  var failure: Error?
  PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
    failure = error
    done.signal()
  }
  done.wait()
  if let failure { throw failure }
  let taken = try MakeThumbnail(source: original, thumb: thumb, metadata: original)
  return taken ?? NSNumber(value: millis(asset.creationDate ?? asset.modificationDate))
}

enum AlbumError: Error, LocalizedError {
  case missing(String)

  var errorDescription: String? {
    switch self {
    case .missing(let message): return message
    }
  }
}

private func flutterAlbumError(_ error: Error) -> FlutterError {
  if let album = error as? AlbumError, case .missing(let message) = album {
    return FlutterError(code: "media", message: message, details: nil)
  }
  let text = error.localizedDescription
  return FlutterError(
    code: "media",
    message: text.isEmpty ? "无法读取系统相册" : text,
    details: nil)
}

/// Handles the album half of the "photoalbum/media" channel. Returns false for
/// methods this file does not own so the caller can try the file thumbnail path.
func registerAlbumMethod(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) -> Bool {
  switch call.method {
  case "permission":
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { next in
        DispatchQueue.main.async { result(permissionName(next)) }
      }
    } else {
      result(permissionName(status))
    }
    return true

  case "snapshot":
    DispatchQueue.global(qos: .userInitiated).async {
      let value = albumSnapshot()
      DispatchQueue.main.async { result(value) }
    }
    return true

  case "scan":
    let arguments = call.arguments as? [String: Any]
    let windows = (arguments?["windows"] as? [String: [String]]) ?? [:]
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
          throw AlbumError.missing("自动备份需要完整照片权限，仍可手动选择照片")
        }
        let rows = try albumScan(windows: windows)
        DispatchQueue.main.async { result(rows) }
      } catch {
        DispatchQueue.main.async { result(flutterAlbumError(error)) }
      }
    }
    return true

  case "metadata":
    let identifier = (call.arguments as? [String: Any])?["source"] as? String ?? ""
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let value = try albumMetadata(identifier: identifier)
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async { result(flutterAlbumError(error)) }
      }
    }
    return true

  case "prepare":
    let arguments = call.arguments as? [String: Any] ?? [:]
    let identifier = arguments["source"] as? String ?? ""
    let original = arguments["original"] as? String ?? ""
    let thumb = arguments["thumb"] as? String ?? ""
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let taken = try albumPrepare(
          identifier: identifier, original: original, thumb: thumb)
        DispatchQueue.main.async { result(taken) }
      } catch {
        DispatchQueue.main.async { result(flutterAlbumError(error)) }
      }
    }
    return true

  default:
    return false
  }
}