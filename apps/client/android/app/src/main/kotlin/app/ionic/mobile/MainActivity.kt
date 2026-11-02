package app.ionic.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val updateVerifier = Executors.newSingleThreadExecutor()
    @Suppress("DEPRECATION")
    private fun flags(): Int = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> {
        val signers = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signers?.map { MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString("") { b -> "%02x".format(b) } }?.toSet() ?: emptySet()
    }
    private fun updatesDir(): File = File(cacheDir, "updates").apply { mkdirs() }.canonicalFile
    @Suppress("DEPRECATION")
    private fun validatedFile(path: String): File {
        val file = File(path).canonicalFile
        require(file.parentFile == updatesDir() && file.name.matches(Regex("update-[a-f0-9]{64}\\.apk")) && file.isFile && file.length() in 1024..(64L * 1024 * 1024))
        val candidate = packageManager.getPackageArchiveInfo(file.path, flags()) ?: error("Unreadable APK")
        val installed = packageManager.getPackageInfo(packageName, flags())
        val expected = signatures(installed)
        require(candidate.packageName == packageName && version(candidate) > version(installed) && expected.isNotEmpty() && signatures(candidate) == expected)
        return file
    }
    private fun canInstall(): Boolean = Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls()
    @Suppress("DEPRECATION")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.ionic/update").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> {
                        val installed = packageManager.getPackageInfo(packageName, flags())
                        result.success(mapOf("versionCode" to version(installed), "version" to installed.versionName, "abis" to Build.SUPPORTED_ABIS.toList(), "updateDirectory" to updatesDir().path, "storeManaged" to (packageManager.getInstallerPackageName(packageName) == "com.android.vending")))
                    }
                    "unmetered" -> result.success(!(getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager).isActiveNetworkMetered)
                    "canInstall" -> result.success(canInstall())
                    "verify", "install" -> {
                        val path = call.argument<String>("path") ?: error("Missing file")
                        updateVerifier.execute {
                            try {
                                val file = validatedFile(path)
                                runOnUiThread {
                                    try {
                                        if (call.method == "verify") {
                                            result.success(true)
                                        } else {
                                            result.success(openUpdate(file))
                                        }
                                    } catch (_: Exception) {
                                        result.error("UPDATE_INVALID", "Không thể mở bản cập nhật Ionic.", null)
                                    }
                                }
                            } catch (_: Exception) {
                                runOnUiThread {
                                    result.error("UPDATE_INVALID", "Bản cập nhật không đúng chữ ký hoặc phiên bản Ionic.", null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("UPDATE_INVALID", "Không thể xác minh hoặc mở bản cập nhật Ionic.", null) }
        }
    }
    private fun openUpdate(file: File): String {
        if (!canInstall()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return "permission_required"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newRawUri("Ionic update", uri)
        })
        return "installer_opened"
    }
    override fun onDestroy() {
        updateVerifier.shutdown()
        super.onDestroy()
    }
}
