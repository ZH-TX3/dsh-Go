package io.github.ccch1mneyyy.dsh_app.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class TreeJsonTest {
    private fun capture(
        vararg windows: UiWindow,
        pkg: String? = "example.app",
        truncated: Boolean = false,
        keyboard: Boolean = false,
    ) = Capture(
        windows = windows.toList(),
        natives = emptyList(),
        keyboardShown = keyboard,
        screen = Box(0, 0, 400, 800),
        packageName = pkg,
        ownAppInFront = false,
        systemInFront = false,
        truncated = truncated,
        takenAt = 0,
    )

    private fun window(vararg nodes: UiNode) =
        UiWindow(1, WindowKind.APP, "example.app", null, Box(0, 0, 400, 800),
            UiNode(bounds = Box(0, 0, 400, 800), children = nodes.toList()))

    @Test fun headerCarriesSeqTimingAndCounts() {
        val json = TreeJson.stringify(capture(window(UiNode(bounds = Box(0, 0, 400, 800)))), 7, 12, 1_000)
        assertTrue(json.startsWith("{\"schema\":\"dsh-a11y-tree/1\",\"seq\":7,\"at\":1000,\"capture_ms\":12"))
        assertTrue(json.contains("\"screen\":[0,0,400,800]"))
        assertTrue(json.contains("\"pkg\":\"example.app\""))
        assertTrue(json.endsWith("\"nodes\":2}")) // the window's root plus the one node in it
    }

    @Test fun aNodeEmitsOnlyWhatItHas() {
        val button = UiNode(ref = 5, className = "android.widget.Button", text = "确定",
            bounds = Box(812, 1990, 1032, 2100), clickable = true, focused = true)
        val plain = UiNode(ref = 6, bounds = Box(0, 0, 10, 10))
        val json = TreeJson.stringify(capture(window(button, plain)), 1, 1, 0)

        assertTrue(json.contains("{\"i\":5,\"d\":1,\"cls\":\"android.widget.Button\",\"text\":\"确定\"," +
            "\"b\":[812,1990,1032,2100],\"flags\":[\"clickable\",\"focused\"],\"children\":[]}"))
        // No class, no text, no flags: nothing but the index, bounds and children.
        assertTrue(json.contains("{\"i\":6,\"d\":1,\"b\":[0,0,10,10],\"children\":[]}"))
    }

    @Test fun scrollDirectionsAndRangesShowUp() {
        val list = UiNode(ref = 2, className = "androidx.recyclerview.widget.RecyclerView",
            bounds = Box(0, 100, 400, 700), scrollable = true,
            scroll = Scroll.FORWARD or Scroll.DOWN, rangeCurrent = 3f, rangeMax = 10f)
        val json = TreeJson.stringify(capture(window(list)), 1, 1, 0)
        assertTrue(json.contains("\"scroll\":[\"forward\",\"down\"]"))
        assertTrue(json.contains("\"range\":[3.0,10.0]"))
    }

    @Test fun textIsEscaped() {
        val node = UiNode(bounds = Box(0, 0, 10, 10), text = "a\"b\\c\nd")
        val json = TreeJson.stringify(capture(window(node)), 1, 1, 0)
        assertTrue(json.contains("\"text\":\"a\\\"b\\\\c\\nd\""))
    }

    @Test fun everyWindowAndTruncationAreReported() {
        val system = UiWindow(2, WindowKind.SYSTEM, null, "通知栏", Box(0, 0, 400, 200), null)
        val json = TreeJson.stringify(capture(window(), system, truncated = true), 1, 1, 0)
        assertTrue(json.contains("\"kind\":\"system\""))
        assertTrue(json.contains("\"title\":\"通知栏\""))
        assertTrue(json.contains("\"root\":null"))
        assertTrue(json.contains("\"truncated\":true"))
        assertEquals(1, TreeJson.count(capture(window(), system))) // the null-root window adds none
    }
}
