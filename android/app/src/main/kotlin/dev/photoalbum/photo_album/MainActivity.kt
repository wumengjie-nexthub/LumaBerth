package dev.photoalbum.photo_album

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var exportFile: String? = null

    private fun filesIntent() = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
        .setType("image/*").putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)

    @Suppress("DEPRECATION")
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "photoalbum/dialogs").setMethodCallHandler { call, result ->
            if (pending != null) {
                result.error("busy", "请先关闭系统选择器", null)
                return@setMethodCallHandler
            }
            pending = result
            try {
                when (call.method) {
                    "pick" -> {
                        val cap = if (Build.VERSION.SDK_INT >= 33) MediaStore.getPickImagesMaxLimit() else 100
                        val intent = Intent("android.provider.action.PICK_IMAGES").setType("image/*")
                            .putExtra("android.provider.extra.PICK_IMAGES_MAX", cap)
                            .putExtra("android.provider.extra.REQUEST_LOCATION_METADATA_ACCESS", true)
                        try { startActivityForResult(intent, PICK) }
                        catch (_: ActivityNotFoundException) { startActivityForResult(filesIntent(), PICK) }
                    }
                    "pickFiles" -> startActivityForResult(filesIntent(), PICK)
                    "permission" -> {
                        val read = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
                        val permissions = mutableListOf(read, Manifest.permission.ACCESS_MEDIA_LOCATION)
                        if (Build.VERSION.SDK_INT >= 34) permissions.add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
                        requestPermissions(permissions.toTypedArray(), PERMISSION)
                    }
                    "export" -> {
                        exportFile = call.argument<String>("path")
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
                        startActivityForResult(intent, EXPORT)
                    }
                    else -> { pending = null; result.notImplemented() }
                }
            } catch (e: Exception) { pending = null; result.error("dialog", e.localizedMessage, null) }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION) {
            pending?.success(null)
            pending = null
        }
    }

    @Deprecated("Flutter forwards plugin results through this callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK && requestCode != EXPORT) return
        val reply = pending ?: return
        pending = null
        try {
            if (requestCode == PICK) {
                val uris = linkedSetOf<Uri>()
                if (resultCode == Activity.RESULT_OK) {
                    data?.data?.let { uris.add(it) }
                    data?.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri) }
                }
                uris.forEach { contentResolver.takePersistableUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                reply.success(uris.map { it.toString() })
            } else {
                val uri = data?.data
                val path = exportFile
                if (resultCode != Activity.RESULT_OK || uri == null || path == null) { reply.success(false); return }
                Thread {
                    try {
                        File(path).inputStream().use { input ->
                            (contentResolver.openOutputStream(uri, "wt") ?: error("无法写入所选位置")).use { input.copyTo(it) }
                        }
                        runOnUiThread { reply.success(true) }
                    } catch (e: Exception) { runOnUiThread { reply.error("export", e.localizedMessage, null) } }
                }.start()
            }
        } catch (e: Exception) { reply.error("picker", e.localizedMessage, null) }
    }

    companion object {
        private const val PICK = 4210
        private const val EXPORT = 4211
        private const val PERMISSION = 4212
    }
}
