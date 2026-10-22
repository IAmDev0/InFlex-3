package zx.offical.inflex

import android.Manifest
import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.MediaStore
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

// ── MainActivity ─────────────────────────────────────────────────────────────
//
// Exposes two native platform channels to Dart:
//
// 1. "inflex/pip" (see lib/services/pip_service.dart):
//      Dart -> native  "isAvailable"   is PiP supported on this device/OS?
//                      "setState"      { allowed, playing }
//                      "enter"         enter PiP immediately
//      native -> Dart  "onModeChanged" PiP just started or ended
//
// 2. "inflex/gallery" (see lib/services/gallery_saver.dart):
//      Dart -> native  "saveVideoToGallery"  { filePath, displayName, mimeType }
//                      Exports a downloaded movie/episode into Movies/InFlex so
//                      Android's Gallery / Photos / file managers show it right
//                      away and keep it permanently even if the app is removed:
//                        • Android 10+ (API 29+): MediaStore.Video.Media with
//                          IS_PENDING (needs zero runtime permissions).
//                        • Android 7–9 (API 24–28): requests legacy
//                          WRITE_EXTERNAL_STORAGE once, copies to Movies/InFlex
//                          and triggers MediaScannerConnection.scanFile().
//                      "getFreeDiskBytes"    { path }
//                      Returns free storage bytes on the volume backing `path`.
class MainActivity : FlutterActivity() {
    private val pipChannelName = "inflex/pip"
    private val galleryChannelName = "inflex/gallery"
    private val storagePermissionRequestCode = 9412

    private var pipChannel: MethodChannel? = null
    private var galleryChannel: MethodChannel? = null

    private var pipAllowed = false
    private var isPlaying = false

    private var pendingLegacySave: (() -> Unit)? = null
    private var pendingLegacyDenied: (() -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        pipChannel = MethodChannel(messenger, pipChannelName).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    "setState" -> {
                        pipAllowed = call.argument<Boolean>("allowed") ?: false
                        isPlaying = call.argument<Boolean>("playing") ?: false
                        result.success(null)
                    }
                    "enter" -> result.success(enterPip())
                    else -> result.notImplemented()
                }
            }
        }

        galleryChannel = MethodChannel(messenger, galleryChannelName).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveVideoToGallery" -> {
                        val filePath = call.argument<String>("filePath")
                        val displayName = call.argument<String>("displayName")
                        val mimeType = call.argument<String>("mimeType") ?: "video/mp4"
                        if (filePath.isNullOrBlank() || displayName.isNullOrBlank()) {
                            result.success(
                                mapOf(
                                    "ok" to false,
                                    "error" to "Invalid file path or display name"
                                )
                            )
                            return@setMethodCallHandler
                        }
                        handleSaveVideoToGallery(filePath, displayName, mimeType, result)
                    }
                    "getFreeDiskBytes" -> {
                        val path = call.argument<String>("path") ?: filesDir.absolutePath
                        try {
                            val target = File(path)
                            val statPath = if (target.exists()) target.absolutePath else filesDir.absolutePath
                            val stat = StatFs(statPath)
                            result.success(stat.availableBytes)
                        } catch (_: Exception) {
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun handleSaveVideoToGallery(
        filePath: String,
        displayName: String,
        mimeType: String,
        result: MethodChannel.Result
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        val sourceFile = File(filePath)
        if (!sourceFile.exists() || !sourceFile.isFile) {
            result.success(
                mapOf(
                    "ok" to false,
                    "error" to "Downloaded video file was not found on device"
                )
            )
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Thread {
                val outcome = copyViaMediaStoreQ(sourceFile, displayName, mimeType)
                mainHandler.post { result.success(outcome) }
            }.start()
            return
        }

        val runLegacyCopy = {
            Thread {
                val outcome = copyLegacyAndScan(sourceFile, displayName, mimeType)
                mainHandler.post { result.success(outcome) }
            }.start()
        }

        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            runLegacyCopy()
        } else {
            pendingLegacySave = runLegacyCopy
            pendingLegacyDenied = {
                result.success(
                    mapOf(
                        "ok" to false,
                        "error" to "Storage permission denied — allow storage access to save videos to Gallery"
                    )
                )
            }
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                storagePermissionRequestCode
            )
        }
    }

    private fun copyViaMediaStoreQ(
        sourceFile: File,
        displayName: String,
        mimeType: String
    ): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return mapOf("ok" to false, "error" to "Unsupported Android version")
        }
        val resolver = applicationContext.contentResolver
        val relativeFolder = "${Environment.DIRECTORY_MOVIES}/InFlex"

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativeFolder)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            ?: return mapOf("ok" to false, "error" to "MediaStore could not create Gallery entry")

        return try {
            val out = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("Could not open MediaStore output stream")
            out.use { output ->
                FileInputStream(sourceFile).use { input ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                }
            }
            val publishValues = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, publishValues, null, null)
            mapOf(
                "ok" to true,
                "location" to "Movies/InFlex/$displayName",
                "uri" to uri.toString()
            )
        } catch (e: Exception) {
            try {
                resolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            mapOf(
                "ok" to false,
                "error" to (e.message ?: "Failed while writing video to Gallery")
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun copyLegacyAndScan(
        sourceFile: File,
        displayName: String,
        mimeType: String
    ): Map<String, Any?> {
        return try {
            val moviesRoot =
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
            val targetDir = File(moviesRoot, "InFlex")
            if (!targetDir.exists() && !targetDir.mkdirs()) {
                return mapOf("ok" to false, "error" to "Could not create Movies/InFlex directory")
            }
            val destFile = File(targetDir, displayName)
            FileInputStream(sourceFile).use { input ->
                FileOutputStream(destFile).use { output ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                }
            }
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(destFile.absolutePath),
                arrayOf(mimeType),
                null
            )
            mapOf(
                "ok" to true,
                "location" to "Movies/InFlex/${destFile.name}"
            )
        } catch (e: Exception) {
            mapOf(
                "ok" to false,
                "error" to (e.message ?: "Failed to save video to Gallery")
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == storagePermissionRequestCode) {
            val saveAction = pendingLegacySave
            val deniedAction = pendingLegacyDenied
            pendingLegacySave = null
            pendingLegacyDenied = null
            if (grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            ) {
                saveAction?.invoke()
            } else {
                deniedAction?.invoke()
            }
        }
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
                .build()
            enterPictureInPictureMode(params)
        } catch (_: Exception) {
            false
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && pipAllowed && isPlaying) {
            enterPip()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onModeChanged", isInPictureInPictureMode)
    }
}
