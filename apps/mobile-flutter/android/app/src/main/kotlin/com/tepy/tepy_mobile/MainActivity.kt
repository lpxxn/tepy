package com.tepy.tepy_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var usbBridge: UsbBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbBridge = UsbBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        usbBridge?.dispose()
        usbBridge = null
        super.onDestroy()
    }

    override fun onStop() {
        usbBridge?.pause()
        super.onStop()
    }
}
