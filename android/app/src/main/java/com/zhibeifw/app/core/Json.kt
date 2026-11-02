package com.zhibeifw.app.core

/**
 * 一个很小的 JSON 解析器（RFC 8259）：对象 → Map<String, Any?>，数组 → List<Any?>，数字 → Double，
 * 字符串 → String，true/false → Boolean，null → JsonNull。语法不对抛 JsonError。
 * 自己写而不用 org.json：后者在 JVM 单元测试里只是空壳，且不想依赖任何第三方库。
 */
object JsonNull

class JsonError(msg: String) : Exception(msg)

object Json {
    /** 嵌套层数上限，防止恶意的深层嵌套把栈撑爆。 */
    private const val MAX_DEPTH = 64

    fun parse(text: String): Any? {
        val p = Parser(text)
        p.ws()
        val v = p.value(0)
        p.ws()
        if (p.i != text.length) throw JsonError("多余的内容")
        return v
    }

    private class Parser(val s: String) {
        var i = 0

        fun ws() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++
        }

        fun value(depth: Int): Any? {
            if (depth > MAX_DEPTH) throw JsonError("嵌套太深")
            if (i >= s.length) throw JsonError("意外结束")
            return when (s[i]) {
                '{' -> obj(depth)
                '[' -> arr(depth)
                '"' -> str()
                't' -> lit("true", true)
                'f' -> lit("false", false)
                'n' -> lit("null", JsonNull)
                else -> num()
            }
        }

        fun lit(word: String, v: Any): Any {
            if (!s.startsWith(word, i)) throw JsonError("不认识的值")
            i += word.length
            return v
        }

        fun obj(depth: Int): Map<String, Any?> {
            i++ // {
            val m = LinkedHashMap<String, Any?>()
            ws()
            if (i < s.length && s[i] == '}') {
                i++; return m
            }
            while (true) {
                ws()
                if (i >= s.length || s[i] != '"') throw JsonError("缺少键")
                val k = str()
                ws()
                if (i >= s.length || s[i] != ':') throw JsonError("缺少冒号")
                i++
                ws()
                m[k] = value(depth + 1)
                ws()
                if (i >= s.length) throw JsonError("意外结束")
                when (s[i]) {
                    ',' -> i++
                    '}' -> {
                        i++; return m
                    }

                    else -> throw JsonError("缺少逗号")
                }
            }
        }

        fun arr(depth: Int): List<Any?> {
            i++ // [
            val a = ArrayList<Any?>()
            ws()
            if (i < s.length && s[i] == ']') {
                i++; return a
            }
            while (true) {
                ws()
                a.add(value(depth + 1))
                ws()
                if (i >= s.length) throw JsonError("意外结束")
                when (s[i]) {
                    ',' -> i++
                    ']' -> {
                        i++; return a
                    }

                    else -> throw JsonError("缺少逗号")
                }
            }
        }

        fun str(): String {
            i++ // "
            val sb = StringBuilder()
            while (true) {
                if (i >= s.length) throw JsonError("字符串没有结束")
                val c = s[i++]
                when {
                    c == '"' -> return sb.toString()
                    c == '\\' -> {
                        if (i >= s.length) throw JsonError("转义不完整")
                        when (val e = s[i++]) {
                            '"' -> sb.append('"'); '\\' -> sb.append('\\'); '/' -> sb.append('/')
                            'b' -> sb.append('\b'); 'f' -> sb.append('\u000C'); 'n' -> sb.append(
                            '\n'
                        )

                            'r' -> sb.append('\r'); 't' -> sb.append('\t')
                            'u' -> {
                                if (i + 4 > s.length) throw JsonError("转义不完整")
                                // 只认 4 位十六进制（toIntOrNull 会接受正负号）
                                val hex = s.substring(i, i + 4)
                                if (!hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) throw JsonError("转义不对")
                                val h = hex.toInt(16)
                                sb.append(h.toChar())
                                i += 4
                            }

                            else -> throw JsonError("不认识的转义 $e")
                        }
                    }

                    c.code < 0x20 -> throw JsonError("字符串里有控制字符")
                    else -> sb.append(c)
                }
            }
        }

        fun num(): Double {
            val start = i
            if (i < s.length && s[i] == '-') i++
            if (i >= s.length) throw JsonError("数字不完整")
            if (s[i] == '0') i++ else if (s[i] in '1'..'9') {
                while (i < s.length && s[i].isAsciiDigit()) i++
            } else throw JsonError("不认识的值")
            if (i < s.length && s[i] == '.') {
                i++;
                val d =
                    i; while (i < s.length && s[i].isAsciiDigit()) i++; if (i == d) throw JsonError(
                    "小数不完整"
                )
            }
            if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
                i++
                if (i < s.length && (s[i] == '+' || s[i] == '-')) i++
                val d = i
                while (i < s.length && s[i].isAsciiDigit()) i++
                if (i == d) throw JsonError("指数不完整")
            }
            return s.substring(start, i).toDouble()
        }

        private fun Char.isAsciiDigit() = this in '0'..'9'
    }

    /** 写出 JSON 字符串（只用于我们自己存的小东西，如域名列表、目录的“规范写法”）。 */
    fun stringify(v: Any?): String = StringBuilder().also { write(it, v) }.toString()

    private fun write(sb: StringBuilder, v: Any?) {
        when (v) {
            null, JsonNull -> sb.append("null")
            is String -> {
                sb.append('"')
                for (c in v) when {
                    c == '"' -> sb.append("\\\""); c == '\\' -> sb.append("\\\\")
                    c == '\n' -> sb.append("\\n"); c == '\r' -> sb.append("\\r"); c == '\t' -> sb.append(
                        "\\t"
                    )

                    c.code < 0x20 -> sb.append("\\u%04x".format(c.code))
                    else -> sb.append(c)
                }
                sb.append('"')
            }

            is Boolean -> sb.append(v)
            is Int, is Long -> sb.append(v)
            is Double -> if (v == Math.floor(v) && !v.isInfinite() && kotlin.math.abs(v) < 1e15) sb.append(
                v.toLong()
            ) else sb.append(v)

            is Number -> sb.append(v)
            is Map<*, *> -> {
                sb.append('{')
                var first = true
                for ((k, x) in v) {
                    if (!first) sb.append(','); first = false; write(sb, k.toString()); sb.append(
                        ':'
                    ); write(sb, x)
                }
                sb.append('}')
            }

            is List<*> -> {
                sb.append('[')
                v.forEachIndexed { idx, x -> if (idx > 0) sb.append(','); write(sb, x) }
                sb.append(']')
            }

            else -> write(sb, v.toString())
        }
    }
}
