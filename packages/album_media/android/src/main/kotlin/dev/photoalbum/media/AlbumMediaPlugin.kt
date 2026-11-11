package dev.photoalbum.media

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.max

class AlbumMediaPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "photoalbum/media")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        io.shutdown()
    }
    private fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    private fun permission(): String {
        val read = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
        return when {
            granted(read) -> "full"
            Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "partial"
            else -> "none"
        }
    }
    private fun snapshot() = MediaStore.getExternalVolumeNames(context).associateWith { volume ->
        mapOf("version" to MediaStore.getVersion(context, volume), "generation" to MediaStore.getGeneration(context, volume))
    }
    private fun scan(call: MethodCall): List<Map<String, Any?>> {
        check(permission() == "full") { "自动备份需要完整照片权限，仍可手动选择照片" }
        val previous = call.argument<Map<String, Map<String, Any?>>>("from").orEmpty()
        val end = call.argument<Map<String, Map<String, Any?>>>("to").orEmpty()
        val result = mutableListOf<Map<String, Any?>>()
        for ((volume, limit) in end) {
            val start = previous[volume]
            check(start == null || start["version"] == limit["version"]) { "系统媒体库已重建，请重新选择自动备份起点" }
            val uri = MediaStore.Images.Media.getContentUri(volume)
            val columns = arrayOf("_id", "_display_name", "_size", "datetaken", "date_added")
            val args = arrayOf((start?.get("generation") ?: 0).toString(), limit["generation"].toString())
            context.contentResolver.query(uri, columns, "generation_added > ? AND generation_added <= ? AND is_pending=0 AND is_trashed=0", args, "_id")?.use {
                while (it.moveToNext()) {
                    val taken = if (it.getLong(3) > 0) it.getLong(3) else it.getLong(4) * 1000
                    result.add(mapOf("source" to ContentUris.withAppendedId(uri, it.getLong(0)).toString(),
                        "name" to it.getString(1), "size" to it.getLong(2), "time" to taken))
                }
            } ?: error("无法读取系统相册")
        }
        return result
    }
    private fun metadata(uri: Uri): Map<String, Any?> {
        val resolver = context.contentResolver
        val projection = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return resolver.query(uri, projection, null, null, null)?.use {
            check(it.moveToFirst()) { "原片已移除，请重新选择" }
            mapOf("source" to uri.toString(), "name" to it.getString(0), "size" to it.getLong(1))
        } ?: error("无法读取所选照片")
    }
    private fun prepare(call: MethodCall): Long? {
        val source = Uri.parse(call.argument<String>("source"))
        val file = File(call.argument<String>("original")!!)
        val thumb = File(call.argument<String>("thumb")!!)
        val uri = if (source.authority == MediaStore.AUTHORITY && !source.path.orEmpty().startsWith("/picker")) {
            check(granted(Manifest.permission.ACCESS_MEDIA_LOCATION)) { "保留原片元数据需要照片位置信息权限，请重新授权" }
            MediaStore.setRequireOriginal(source)
        } else source
        context.contentResolver.openInputStream(uri)?.use { input ->
            file.outputStream().use { output -> input.copyTo(output) }
        } ?: error("无法读取原片，请重新选择或授权")
        check(file.length() < 2147483648L) { "原片必须小于 2 GiB" }
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            val ratio = minOf(1.0, 480.0 / max(info.size.width, info.size.height))
            decoder.setTargetSize(max(1, (info.size.width * ratio).toInt()), max(1, (info.size.height * ratio).toInt()))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        thumb.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it)) }
        bitmap.recycle()
        return runCatching { android.media.ExifInterface(file.path).getAttribute(android.media.ExifInterface.TAG_DATETIME_ORIGINAL) }
            .getOrNull()?.let { runCatching { java.text.SimpleDateFormat("yyyy:MM:dd HH:mm:ss", java.util.Locale.US).parse(it)?.time }.getOrNull() }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        io.execute {
            try {
                val value: Any? = when (call.method) {
                    "permission" -> permission()
                    "snapshot" -> snapshot()
                    "scan" -> scan(call)
                    "metadata" -> metadata(Uri.parse(call.argument<String>("source")))
                    "prepare" -> prepare(call)
                    else -> { main.post { result.notImplemented() }; return@execute }
                }
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("media", e.localizedMessage ?: "照片读取失败", null) }
            }
        }
    }
}
