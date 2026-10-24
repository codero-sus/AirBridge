package com.coderosus.airbridge_mobile

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import java.net.Inet4Address
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.coderosus.airbridge_mobile/network"
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getWifiIPv4Address" -> {
                        try {
                            result.success(getWifiIPv4Address())
                        } catch (error: SecurityException) {
                            result.error("NETWORK_PERMISSION", error.message, null)
                        } catch (error: RuntimeException) {
                            result.error("NETWORK_LOOKUP", error.message, null)
                        }
                    }
                    "acquireMulticastLock" -> {
                        try {
                            acquireMulticastLock()
                            result.success(true)
                        } catch (error: SecurityException) {
                            result.error("MULTICAST_PERMISSION", error.message, null)
                        } catch (error: RuntimeException) {
                            result.error("MULTICAST_LOCK", error.message, null)
                        }
                    }
                    "releaseMulticastLock" -> {
                        releaseMulticastLock()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun getWifiIPv4Address(): String? {
        val connectivityManager =
            applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        for (network in connectivityManager.allNetworks) {
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            val properties = connectivityManager.getLinkProperties(network) ?: continue
            val address = properties.linkAddresses
                .map { it.address }
                .filterIsInstance<Inet4Address>()
                .firstOrNull {
                    !it.isAnyLocalAddress && !it.isLoopbackAddress && !it.isLinkLocalAddress
                }
            if (address != null) return address.hostAddress
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifiManager.createMulticastLock("AirbridgeUdpDiscovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        val lock = multicastLock
        if (lock?.isHeld == true) lock.release()
        multicastLock = null
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }
}
