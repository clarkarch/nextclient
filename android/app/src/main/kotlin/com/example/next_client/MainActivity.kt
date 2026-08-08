package com.example.next_client

import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "next_client/gamepad"

        // XInput-style flags, matching gfn_input_protocol.dart.
        private const val DPAD_UP = 0x0001
        private const val DPAD_DOWN = 0x0002
        private const val DPAD_LEFT = 0x0004
        private const val DPAD_RIGHT = 0x0008
        private const val DPAD_MASK = DPAD_UP or DPAD_DOWN or DPAD_LEFT or DPAD_RIGHT
        private const val START = 0x0010
        private const val BACK = 0x0020
        private const val LS = 0x0040
        private const val RS = 0x0080
        private const val LB = 0x0100
        private const val RB = 0x0200
        private const val GUIDE = 0x0400
        private const val A = 0x1000
        private const val B = 0x2000
        private const val X = 0x4000
        private const val Y = 0x8000
    }

    private var channel: MethodChannel? = null
    private var buttons = 0
    private var lx = 0.0
    private var ly = 0.0
    private var rx = 0.0
    private var ry = 0.0
    private var lt = 0.0
    private var rt = 0.0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // A re-attached engine re-runs configure; null the old channel so a
        // stale messenger isn't reused.
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    }

    private fun sendState() {
        channel?.invokeMethod(
            "state",
            mapOf(
                "buttons" to buttons,
                "lx" to lx, "ly" to ly,
                "rx" to rx, "ry" to ry,
                "lt" to lt, "rt" to rt,
            ),
        )
    }

    private fun keyToFlag(keyCode: Int): Int =
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> DPAD_UP
            KeyEvent.KEYCODE_DPAD_DOWN -> DPAD_DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> DPAD_LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> DPAD_RIGHT
            KeyEvent.KEYCODE_BUTTON_START -> START
            KeyEvent.KEYCODE_BUTTON_SELECT -> BACK
            KeyEvent.KEYCODE_BUTTON_L1 -> LB
            KeyEvent.KEYCODE_BUTTON_R1 -> RB
            KeyEvent.KEYCODE_BUTTON_A -> A
            KeyEvent.KEYCODE_BUTTON_B -> B
            KeyEvent.KEYCODE_BUTTON_X -> X
            KeyEvent.KEYCODE_BUTTON_Y -> Y
            KeyEvent.KEYCODE_BUTTON_MODE -> GUIDE
            else -> 0
        }

    // The FlutterView's own key handling consumes gamepad keycodes before the
    // Activity's onKeyDown is reached; dispatchKeyEvent is the first stop in
    // the window's key pipeline, so gamepad buttons are intercepted here.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val flag = keyToFlag(event.keyCode)
        if (flag != 0) {
            buttons = if (event.action == KeyEvent.ACTION_DOWN) {
                buttons or flag
            } else {
                buttons and flag.inv()
            }
            sendState()
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    private fun normalize(value: Float): Double {
        val v = if (Math.abs(value) < 0.15f) 0.0 else value.toDouble()
        return v.coerceIn(-1.0, 1.0)
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if ((event.source and InputDevice.SOURCE_JOYSTICK) == 0) {
            return super.onGenericMotionEvent(event)
        }
        lx = normalize(event.getAxisValue(MotionEvent.AXIS_X))
        ly = normalize(event.getAxisValue(MotionEvent.AXIS_Y))
        rx = normalize(event.getAxisValue(MotionEvent.AXIS_Z))
        ry = normalize(event.getAxisValue(MotionEvent.AXIS_RZ))
        lt = normalize(event.getAxisValue(MotionEvent.AXIS_LTRIGGER))
        rt = normalize(event.getAxisValue(MotionEvent.AXIS_RTRIGGER))
        // D-pads are usually a hat axis, not key events — merge them into the
        // button bitmap here so arrows work too.
        val hatX = event.getAxisValue(MotionEvent.AXIS_HAT_X)
        val hatY = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
        buttons = buttons and DPAD_MASK.inv()
        if (hatX <= -0.5f) buttons = buttons or DPAD_LEFT
        if (hatX >= 0.5f) buttons = buttons or DPAD_RIGHT
        if (hatY <= -0.5f) buttons = buttons or DPAD_UP
        if (hatY >= 0.5f) buttons = buttons or DPAD_DOWN
        sendState()
        return true
    }
}