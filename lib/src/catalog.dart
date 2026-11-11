import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

typedef Json = Map<String, dynamic>;

const maxAssetBytes = 2 * 1024 * 1024 * 1024;
bool hasRoom(int assets, {int needed = 2}) => assets + needed <= 1000;
String indexPath(String id) => 'photo-album/v1/${id.substring(0, 2)}/$id.json';
String checksum(List<int> bytes) => sha256.convert(bytes).toString();
Future<String> fileHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
String encodeIndex(Json entry) =>
    '${jsonEncode({
      'version': 1,
      'photos': [entry],
    })}\n';
List<Json> decodeIndex(String raw) {
  final batch = jsonDecode(raw) as Json;
  if (batch['version'] != 1) throw const FormatException('相册目录版本不受支持');
  return (batch['photos'] as List).cast<Json>().map((photo) {
    if (photo['id'] is! String ||
        !RegExp(r'^[0-9a-f-]{36}$').hasMatch(photo['id']) ||
        photo['name'] is! String ||
        int.tryParse('${photo['size']}') == null ||
        photo['original'] is! int ||
        photo['thumbnail'] is! int ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch('${photo['sha256']}') ||
        DateTime.tryParse('${photo['takenAt']}') == null) {
      throw const FormatException('相册目录记录不完整');
    }
    return photo;
  }).toList();
}

String exportName(String original) {
  var name = p.windows
      .basename(original)
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceFirst(RegExp(r'[ .]+$'), '');
  if (name.isEmpty) name = 'photo';
  if (RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  return name;
}

Future<File> exportVerified(
  File verified,
  Directory directory,
  String original,
) async {
  final name = exportName(original);
  for (var i = 0; ; i++) {
    final suffix = i == 0
        ? name
        : '${p.basenameWithoutExtension(name)} ($i)${p.extension(name)}';
    final output = File(p.join(directory.path, suffix));
    try {
      await output.create(exclusive: true);
    } on PathExistsException {
      continue;
    }
    try {
      final sink = output.openWrite();
      try {
        await sink.addStream(verified.openRead());
      } finally {
        await sink.close();
      }
      return output;
    } catch (_) {
      await output.delete();
      rethrow;
    }
  }
}
