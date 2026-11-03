package com.zhibeifw.app

import com.zhibeifw.app.core.Json
import com.zhibeifw.app.core.JsonNull
import com.zhibeifw.app.core.clock
import com.zhibeifw.app.core.compareVersions
import com.zhibeifw.app.core.coverRequestPx
import com.zhibeifw.app.core.fileKey
import com.zhibeifw.app.core.isHttpsOrigin
import com.zhibeifw.app.core.isValidId
import com.zhibeifw.app.core.isValidRelativePath
import com.zhibeifw.app.core.normalizeText
import com.zhibeifw.app.core.placeholderIndex
import com.zhibeifw.app.core.remainingClock
import com.zhibeifw.app.core.utf16Prefix
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// 两端共用的测试数据（仓库根目录 doc/test-vectors/*.json）：iOS 的 TestVectorTests.swift 读同一份，用例不会两边抄岔。
// 单元测试的工作目录是 android/app。
class TestVectorTest {
    private fun load(name: String): Map<*, *> =
        Json.parse(File("../../doc/test-vectors/$name.json").readText()) as Map<*, *>

    /** JSON 里的 null 读出来是 JsonNull，传给被测函数时换成 null */
    private fun value(v: Any?): Any? = if (v == JsonNull) null else v

    private fun cases(v: Map<*, *>, k: String) = (v[k] as List<*>).map { it as List<*> }
    private fun list(v: Map<*, *>, k: String) = v[k] as List<*>

    @Test
    fun versions() {
        val v = load("versions")
        for (c in cases(v, "compare")) assertEquals("$c", (c[2] as Double).toInt(), compareVersions(c[0], c[1]))
        for (c in cases(v, "invalid")) assertNull("$c", compareVersions(value(c[0]), value(c[1])))
    }

    @Test
    fun ids() {
        val v = load("ids")
        for (s in list(v, "valid")) assertTrue("$s", isValidId(s))
        for (s in list(v, "invalid")) assertFalse("$s", isValidId(s))
    }

    @Test
    fun paths() {
        val v = load("paths")
        for (s in list(v, "valid")) assertTrue("$s", isValidRelativePath(s))
        for (s in list(v, "invalid")) assertFalse("$s", isValidRelativePath(s))
    }

    @Test
    fun origins() {
        val v = load("origins")
        for (s in list(v, "valid")) assertTrue("$s", isHttpsOrigin(s as String))
        for (s in list(v, "invalid")) assertFalse("$s", isHttpsOrigin(s as String))
    }

    @Test
    fun fileKeys() {
        val v = load("filekey")
        for (c in cases(v, "fileKey")) assertEquals("$c", c[1], fileKey(c[0] as String))
        for (c in cases(v, "placeholderIndex")) assertEquals("$c", (c[1] as Double).toInt(), placeholderIndex(c[0] as String))
    }

    @Test
    fun text() {
        val v = load("text")
        for (c in cases(v, "normalize")) assertEquals(c[1], normalizeText(c[0] as String))
        for (c in cases(v, "clock")) assertEquals("$c", c[1], clock(c[0] as Double))
        for (c in cases(v, "remainingClock")) assertEquals("$c", c[2], remainingClock(c[0] as Double, c[1] as Double))
        for (c in cases(v, "coverRequestPx"))
            assertEquals("$c", (c[1] as Double).toInt(), coverRequestPx((c[0] as Double).toInt()))
        for (c in cases(v, "utf16Prefix")) assertEquals("$c", c[2], utf16Prefix(c[0] as String, (c[1] as Double).toInt()))
    }
}
