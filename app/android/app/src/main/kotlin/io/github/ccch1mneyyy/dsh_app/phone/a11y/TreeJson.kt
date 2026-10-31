package io.github.ccch1mneyyy.dsh_app.phone.a11y

/**
 * A [Capture] as JSON, for `adb shell am broadcast … --es cmd dump`.
 *
 * A plain function of the capture — no `AccessibilityNodeInfo` here — so the shape is stable
 * and the tree keeps exactly what [TreeCapture] read. Nothing is interpreted, reordered or
 * de-duplicated: `i` is the capture's native index, the same one `target` / `tap` take as `id`.
 *
 * ```
 * { "schema": "dsh-a11y-tree/1", "seq": 7, "at": 1761000000000, "capture_ms": 38,
 *   "screen": [0,0,1080,2400], "pkg": "com.android.settings",
 *   "keyboard": false, "dsh_in_front": false, "system_in_front": false, "truncated": false,
 *   "windows": [ { "id": 12, "kind": "app", "pkg": "...", "title": "...", "bounds": [l,t,r,b],
 *                  "root": <node> } ],
 *   "nodes": 412 }
 * ```
 *
 * A node emits only what it has; every field but `i`, `b` and `children` is optional.
 *
 * ```
 * { "i": 12, "d": 2, "cls": "android.widget.Button", "text": "确定", "desc": "…", "hint": "…",
 *   "rid": "com.foo:id/ok", "b": [812,1990,1032,2100],
 *   "flags": ["clickable","focused"], "scroll": ["forward","down"], "role": "button",
 *   "state": "已选中", "range": [3.0,10.0], "children": [] }
 * ```
 *
 * `flags`: clickable, long_clickable, editable, scrollable, checkable, checked, selected,
 * focused, disabled, password, heading, hint_shown. `scroll` is what the node can do now.
 * `d` is depth (the root is 0 and omits it).
 */
internal object TreeJson {
    const val SCHEMA = "dsh-a11y-tree/1"

    /** Beyond this the recursion stops; trees are far shallower (TreeCapture caps at 80 too). */
    private const val MAX_DEPTH = 200

    fun stringify(cap: Capture, seq: Int, captureMs: Long, at: Long = System.currentTimeMillis()): String {
        val out = Out()
        val sb = out.sb
        sb.append("{\"schema\":\"").append(SCHEMA).append('"')
        sb.append(",\"seq\":").append(seq)
        sb.append(",\"at\":").append(at)
        sb.append(",\"capture_ms\":").append(captureMs)
        sb.append(",\"screen\":")
        box(out, cap.screen)
        cap.packageName?.let { sb.append(",\"pkg\":"); string(out, it) }
        sb.append(",\"keyboard\":").append(cap.keyboardShown)
        sb.append(",\"dsh_in_front\":").append(cap.ownAppInFront)
        sb.append(",\"system_in_front\":").append(cap.systemInFront)
        sb.append(",\"truncated\":").append(cap.truncated)
        cap.hiddenWindowTitle?.let { sb.append(",\"hidden_window\":"); string(out, it) }
        sb.append(",\"windows\":[")
        cap.windows.forEachIndexed { index, w ->
            if (index > 0) sb.append(',')
            window(out, w)
        }
        // The count reads better at the end: it is only known once the trees are written.
        sb.append("],\"nodes\":").append(out.nodes)
        sb.append('}')
        return sb.toString()
    }

    /** How many nodes the capture holds (what `"nodes"` reports, without building the JSON). */
    fun count(cap: Capture): Int = cap.windows.sumOf { w -> w.root?.let { nodeCount(it) } ?: 0 }

    private fun nodeCount(n: UiNode): Int = 1 + n.children.sumOf { nodeCount(it) }

    private class Out {
        val sb = StringBuilder(1 shl 16)
        var nodes = 0
        val flags = ArrayList<String>(6)
        val scroll = ArrayList<String>(3)
    }

    private fun window(out: Out, w: UiWindow) {
        val sb = out.sb
        sb.append("{\"id\":").append(w.id)
        sb.append(",\"kind\":").append(if (w.kind == WindowKind.SYSTEM) "\"system\"" else "\"app\"")
        w.packageName?.let { sb.append(",\"pkg\":"); string(out, it) }
        w.title?.let { sb.append(",\"title\":"); string(out, it) }
        sb.append(",\"bounds\":")
        box(out, w.bounds)
        sb.append(",\"root\":")
        val root = w.root
        if (root == null) sb.append("null") else node(out, root, 0)
        sb.append('}')
    }

    private fun node(out: Out, n: UiNode, depth: Int) {
        val sb = out.sb
        out.nodes++
        sb.append("{\"i\":").append(n.ref)
        if (depth > 0) sb.append(",\"d\":").append(depth)
        if (n.className.isNotEmpty()) { sb.append(",\"cls\":"); string(out, n.className) }
        n.text?.takeIf { it.isNotEmpty() }?.let { sb.append(",\"text\":"); string(out, it) }
        n.desc?.takeIf { it.isNotEmpty() }?.let { sb.append(",\"desc\":"); string(out, it) }
        n.hint?.takeIf { it.isNotEmpty() }?.let { sb.append(",\"hint\":"); string(out, it) }
        n.viewId?.takeIf { it.isNotEmpty() }?.let { sb.append(",\"rid\":"); string(out, it) }
        sb.append(",\"b\":")
        box(out, n.bounds)

        out.flags.clear()
        if (n.clickable) out.flags += "clickable"
        if (n.longClickable) out.flags += "long_clickable"
        if (n.editable) out.flags += "editable"
        if (n.scrollable) out.flags += "scrollable"
        if (n.checkable) out.flags += "checkable"
        if (n.checked) out.flags += "checked"
        if (n.selected) out.flags += "selected"
        if (n.focused) out.flags += "focused"
        if (!n.enabled) out.flags += "disabled"
        if (n.password) out.flags += "password"
        if (n.heading) out.flags += "heading"
        if (n.showingHint) out.flags += "hint_shown"
        if (out.flags.isNotEmpty()) { sb.append(",\"flags\":"); strings(out, out.flags) }

        out.scroll.clear()
        if (n.scroll and Scroll.FORWARD != 0) out.scroll += "forward"
        if (n.scroll and Scroll.BACKWARD != 0) out.scroll += "backward"
        if (n.scroll and Scroll.UP != 0) out.scroll += "up"
        if (n.scroll and Scroll.DOWN != 0) out.scroll += "down"
        if (n.scroll and Scroll.LEFT != 0) out.scroll += "left"
        if (n.scroll and Scroll.RIGHT != 0) out.scroll += "right"
        if (out.scroll.isNotEmpty()) { sb.append(",\"scroll\":"); strings(out, out.scroll) }

        n.roleHint?.takeIf { it.isNotEmpty() }?.let { sb.append(",\"role\":"); string(out, it) }
        n.stateDesc?.takeIf { it.isNotEmpty() }?.let { sb.append(",\"state\":"); string(out, it) }
        val current = n.rangeCurrent
        val max = n.rangeMax
        if (current != null || max != null) {
            sb.append(",\"range\":[")
            if (current != null) sb.append(current) else sb.append("null")
            sb.append(',')
            if (max != null) sb.append(max) else sb.append("null")
            sb.append(']')
        }

        sb.append(",\"children\":[")
        if (depth < MAX_DEPTH) {
            n.children.forEachIndexed { index, child ->
                if (index > 0) sb.append(',')
                node(out, child, depth + 1)
            }
        }
        sb.append("]}")
    }

    private fun box(out: Out, b: Box) {
        out.sb.append('[').append(b.left).append(',').append(b.top).append(',')
            .append(b.right).append(',').append(b.bottom).append(']')
    }

    private fun strings(out: Out, values: List<String>) {
        val sb = out.sb
        sb.append('[')
        values.forEachIndexed { index, value ->
            if (index > 0) sb.append(',')
            string(out, value)
        }
        sb.append(']')
    }

    private fun string(out: Out, value: String) {
        val sb = out.sb
        sb.append('"')
        for (c in value) when {
            c == '"' -> sb.append("\\\"")
            c == '\\' -> sb.append("\\\\")
            c == '\n' -> sb.append("\\n")
            c == '\r' -> sb.append("\\r")
            c == '\t' -> sb.append("\\t")
            c < ' ' -> sb.append("\\u").append(c.code.toString(16).padStart(4, '0'))
            else -> sb.append(c)
        }
        sb.append('"')
    }
}
