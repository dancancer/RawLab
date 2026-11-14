package com.rawlab.android.presets

// P2-16 严格 JSON 扫描（与 Shared/PresetJSONScanner.swift、Windows JsonDocument 同一合同）：
// 拒绝尾逗号、注释、重复键、非标准数字；条目子树内的重复键只降级单条，不再整库报废。
// 每个节点带原文偏移，坏条目可以按字节透传保留。

internal class PresetScanException : Exception()

internal sealed class JSONScan(val start: Int, val end: Int) {
    class Obj(val members: List<Pair<String, JSONScan>>, val ownDuplicate: Boolean, val subtreeDuplicate: Boolean,
        start: Int, end: Int) : JSONScan(start, end)
    class Arr(val items: List<JSONScan>, val subtreeDuplicate: Boolean, start: Int, end: Int) : JSONScan(start, end)
    class Str(val value: String, start: Int, end: Int) : JSONScan(start, end)
    class Num(val literal: String, start: Int, end: Int) : JSONScan(start, end)
    object Bool : JSONScan(0, 0)
    object Nul : JSONScan(0, 0)
}

internal fun scanPresetJSON(text: String): JSONScan {
    val scanner = PresetScanner(text)
    val root = scanner.value(0)
    scanner.whitespace()
    if (scanner.index != text.length) throw PresetScanException()
    return root
}

internal fun isIntegerLiteral(literal: String): Boolean {
    val digits = if (literal.startsWith("-")) literal.substring(1) else literal
    return digits.isNotEmpty() && digits.all { it in '0'..'9' }
}

// 条目内任何深度的 created_at/updated_at 都只接受整数字面量（与 Windows/Swift 同语义）。
internal fun timestampsAreIntegers(node: JSONScan): Boolean = when (node) {
    is JSONScan.Obj -> node.members.all { (key, child) ->
        (key != "created_at" && key != "updated_at" || child is JSONScan.Num && isIntegerLiteral(child.literal)) &&
            timestampsAreIntegers(child)
    }
    is JSONScan.Arr -> node.items.all { timestampsAreIntegers(it) }
    else -> true
}

internal fun directString(node: JSONScan?, key: String): String? =
    ((node as? JSONScan.Obj)?.members?.firstOrNull { it.first == key }?.second as? JSONScan.Str)?.value

private class PresetScanner(private val text: String) {
    var index = 0

    fun whitespace() {
        while (index < text.length && (text[index] == ' ' || text[index] == '\t' || text[index] == '\r' || text[index] == '\n')) index++
    }

    fun value(depth: Int): JSONScan {
        if (depth > 64) throw PresetScanException()
        whitespace()
        if (index >= text.length) throw PresetScanException()
        val start = index
        return when (text[index]) {
            '{' -> objectValue(depth, start)
            '[' -> arrayValue(depth, start)
            '"' -> JSONScan.Str(string(), start, index)
            't' -> literal("true", start)
            'f' -> literal("false", start)
            'n' -> literal("null", start)
            else -> numberValue(start)
        }
    }

    private fun objectValue(depth: Int, start: Int): JSONScan {
        index++
        val members = mutableListOf<Pair<String, JSONScan>>()
        val seen = mutableSetOf<String>()
        var ownDuplicate = false
        var nested = false
        whitespace()
        if (consume('}')) return JSONScan.Obj(members, false, false, start, index)
        while (true) {
            whitespace()
            if (peek() != '"') throw PresetScanException()
            val key = string()
            whitespace()
            if (!consume(':')) throw PresetScanException()
            val child = value(depth + 1)
            nested = nested || hasDuplicate(child)
            if (!seen.add(key)) ownDuplicate = true
            members.add(key to child)
            whitespace()
            if (consume('}')) break
            if (!consume(',')) throw PresetScanException()
        }
        return JSONScan.Obj(members, ownDuplicate, ownDuplicate || nested, start, index)
    }

    private fun arrayValue(depth: Int, start: Int): JSONScan {
        index++
        val items = mutableListOf<JSONScan>()
        var nested = false
        whitespace()
        if (consume(']')) return JSONScan.Arr(items, false, start, index)
        while (true) {
            val item = value(depth + 1)
            nested = nested || hasDuplicate(item)
            items.add(item)
            whitespace()
            if (consume(']')) break
            if (!consume(',')) throw PresetScanException()
        }
        return JSONScan.Arr(items, nested, start, index)
    }

    private fun numberValue(start: Int): JSONScan {
        while (index < text.length && text[index] in "-0123456789.eE+") index++
        val literal = text.substring(start, index)
        if (!isValidNumber(literal)) throw PresetScanException()
        return JSONScan.Num(literal, start, index)
    }

    private fun literal(expected: String, start: Int): JSONScan {
        if (!text.startsWith(expected, index)) throw PresetScanException()
        index += expected.length
        return if (expected == "null") JSONScan.Nul else JSONScan.Bool
    }

    private fun peek(): Char? = text.getOrNull(index)

    private fun consume(char: Char): Boolean {
        if (peek() != char) return false
        index++
        return true
    }

    private fun string(): String {
        index++
        val out = StringBuilder()
        while (index < text.length) {
            val char = text[index]
            if (char == '"') { index++; return out.toString() }
            if (char == '\\') {
                index++
                when (val escape = peek()) {
                    '"' -> { out.append('"'); index++ }
                    '\\' -> { out.append('\\'); index++ }
                    '/' -> { out.append('/'); index++ }
                    'b' -> { out.append('\b'); index++ }
                    'f' -> { out.append('\u000C'); index++ }
                    'n' -> { out.append('\n'); index++ }
                    'r' -> { out.append('\r'); index++ }
                    't' -> { out.append('\t'); index++ }
                    'u' -> {
                        index++
                        val high = hex4()
                        if (high in 0xD800..0xDBFF) {
                            if (peek() != '\\' || text.getOrNull(index + 1) != 'u') throw PresetScanException()
                            index += 2
                            val low = hex4()
                            if (low !in 0xDC00..0xDFFF) throw PresetScanException()
                            out.append(String(Character.toChars(0x10000 + ((high - 0xD800) shl 10) + (low - 0xDC00))))
                        } else if (high in 0xDC00..0xDFFF) {
                            throw PresetScanException() // 落单的低代理项
                        } else {
                            out.append(high.toChar())
                        }
                    }
                    else -> throw PresetScanException()
                }
            } else {
                if (char.code < 0x20) throw PresetScanException()
                out.append(char)
                index++
            }
        }
        throw PresetScanException() // 未闭合字符串
    }

    private fun hex4(): Int {
        var code = 0
        repeat(4) {
            val digit = text.getOrNull(index) ?: throw PresetScanException()
            val value = when (digit) {
                in '0'..'9' -> digit - '0'
                in 'a'..'f' -> digit - 'a' + 10
                in 'A'..'F' -> digit - 'A' + 10
                else -> throw PresetScanException()
            }
            code = code * 16 + value
            index++
        }
        return code
    }

    // 标准 JSON 数字：-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?；拒绝前导零、+.5、1.、1e。
    private fun isValidNumber(literal: String): Boolean {
        var rest = literal
        if (rest.startsWith("-")) rest = rest.substring(1)
        if (rest.isEmpty() || rest[0] !in '0'..'9') return false
        if (rest[0] == '0') {
            rest = rest.substring(1)
            if (rest.isNotEmpty() && rest[0] in '0'..'9') return false
        } else {
            while (rest.isNotEmpty() && rest[0] in '0'..'9') rest = rest.substring(1)
        }
        if (rest.startsWith(".")) {
            rest = rest.substring(1)
            var digits = 0
            while (rest.isNotEmpty() && rest[0] in '0'..'9') { rest = rest.substring(1); digits++ }
            if (digits == 0) return false
        }
        if (rest.startsWith("e") || rest.startsWith("E")) {
            rest = rest.substring(1)
            if (rest.startsWith("+") || rest.startsWith("-")) rest = rest.substring(1)
            var digits = 0
            while (rest.isNotEmpty() && rest[0] in '0'..'9') { rest = rest.substring(1); digits++ }
            if (digits == 0) return false
        }
        return rest.isEmpty()
    }
}

private fun hasDuplicate(node: JSONScan): Boolean = when (node) {
    is JSONScan.Obj -> node.subtreeDuplicate
    is JSONScan.Arr -> node.subtreeDuplicate
    else -> false
}
