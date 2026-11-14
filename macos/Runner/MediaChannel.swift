import Cocoa
import FlutterMacOS
import ImageIO
import UniformTypeIdentifiers

/// macOS implementation of the "photoalbum/media" channel, mirroring the
/// Windows WIC handler: a 480px JPEG thumbnail with EXIF orientation applied,
/// plus the EXIF capture time in milliseconds (nil when absent).
func RegisterMediaChannel(messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(
    name: "photoalbum/media", binaryMessenger: messenger)
  channel.setMethodCallHandler { call, result in
    if registerAlbumMethod(call, result) { return }
    guard call.method == "thumbnail",
      let args = call.arguments as? [String: Any],
      let source = args["source"] as? String,
      let thumb = args["thumb"] as? String,
      let metadata = args["metadata"] as? String
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let taken = try MakeThumbnail(source: source, thumb: thumb, metadata: metadata)
        DispatchQueue.main.async { result(taken) }
      } catch ThumbnailError.missing {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "media",
            message: "这张照片已不在原来的位置，请重新选择",
            details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "codec",
            message: "macOS 无法解码这张照片，HEIC 等格式需要系统解码器支持。",
            details: nil))
        }
      }
    }
  }
}

enum ThumbnailError: Error {
  case missing
  case unreadable
  case encode
}

func MakeThumbnail(source: String, thumb: String, metadata: String) throws -> NSNumber? {
  let sourceURL = URL(fileURLWithPath: source)
  // A photo the user moved or deleted is not a decoder problem.
  guard FileManager.default.fileExists(atPath: source) else {
    throw ThumbnailError.missing
  }
  guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
    throw ThumbnailError.unreadable
  }
  let options: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: 480,
  ]
  guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
    throw ThumbnailError.unreadable
  }
  let thumbURL = URL(fileURLWithPath: thumb)
  guard let destination = CGImageDestinationCreateWithURL(
    thumbURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
    throw ThumbnailError.encode
  }
  let properties: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: 0.9,
  ]
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  guard CGImageDestinationFinalize(destination) else {
    throw ThumbnailError.encode
  }
  return TakenAt(metadata)
}

func TakenAt(_ path: String) -> NSNumber? {
  let url = URL(fileURLWithPath: path)
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
  else {
    return nil
  }
  let raw = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
    ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
  guard let raw else { return nil }
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
  guard let date = formatter.date(from: raw) else { return nil }
  return NSNumber(value: Int64(date.timeIntervalSince1970 * 1000))
}
