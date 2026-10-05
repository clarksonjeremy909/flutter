package com.aktifdesk.aktifdesk

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val moonlightPackages = listOf("com.limelight", "com.limelight.root", "com.limelight.debug")
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onDestroy() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aktifdesk/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moonlightPackage" -> result.success(findMoonlight())
                    "launchMoonlight" -> {
                        val pkg = findMoonlight()
                        if (pkg == null) {
                            result.success(false)
                        } else {
                            // Moonlight's exported ShortcutTrampoline starts a stream for a
                            // known (paired) PC by UUID and optional app id/name.
                            val i = Intent().apply {
                                component = ComponentName(pkg, "com.limelight.ShortcutTrampoline")
                                putExtra("UUID", call.argument<String>("uuid"))
                                call.argument<String>("pcName")?.let { putExtra("Name", it); putExtra("PcName", it) }
                                call.argument<String>("appId")?.let { putExtra("AppId", it) }
                                call.argument<String>("appName")?.let { putExtra("AppName", it) }
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            try {
                                startActivity(i)
                                result.success(true)
                            } catch (e: ActivityNotFoundException) {
                                result.success(false)
                            } catch (e: SecurityException) {
                                result.success(false)
                            }
                        }
                    }
                    "openMoonlight" -> {
                        val pkg = findMoonlight()
                        val i = pkg?.let { packageManager.getLaunchIntentForPackage(it) }
                        if (i != null) startActivity(i)
                        result.success(i != null)
                    }
                    "openStore" -> {
                        val p = call.argument<String>("package") ?: "com.limelight"
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$p")))
                        } catch (e: ActivityNotFoundException) {
                            startActivity(Intent(Intent.ACTION_VIEW,
                                Uri.parse("https://play.google.com/store/apps/details?id=$p")))
                        }
                        result.success(true)
                    }
                    "keepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        runOnUiThread {
                            if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(true)
                    }
                    "multicastLock" -> {
                        val on = call.argument<Boolean>("on") ?: true
                        try {
                            if (on) {
                                val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                                val lock = multicastLock ?: wifi.createMulticastLock("aktifdesk-discovery").also {
                                    it.setReferenceCounted(false)
                                    multicastLock = it
                                }
                                if (!lock.isHeld) lock.acquire()
                            } else {
                                multicastLock?.let { if (it.isHeld) it.release() }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun findMoonlight(): String? = moonlightPackages.firstOrNull { pkg ->
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(pkg, 0)
            }
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }
}
