package com.rawlab.android.json

import org.json.JSONTokener

/** JSONObject 在 Android 接受宽松语法；持久化记录先检查标准 JSON、重复 key 和整数元数据。 */
internal fun validateStrictJSON(text: String, integerKeys: Set<String> = emptySet()) = StrictJSONTokens(text, integerKeys).validate()

private class StrictJSONTokens(private val text: String, private val metadata: Set<String>) {
    private var index = 0
    private val number = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")
    private val integer = Regex("-?(0|[1-9][0-9]*)")

    fun validate() {
        value(0)
        whitespace()
        requireValid(index == text.length)
    }

    private fun value(depth: Int, integerMetadata: Boolean = false) {
        requireValid(depth < 64)
        whitespace()
        if (integerMetadata) {
            val token = numberToken()
            requireValid(integer.matches(token) && token.toLongOrNull() != null)
            return
        }
        when (text.getOrNull(index)) {
            '{' -> {
                index++; whitespace()
                if (consume('}')) return
                val keys = mutableSetOf<String>()
                while (true) {
                    whitespace()
                    val key = string()
                    requireValid(keys.add(key))
                    whitespace(); requireValid(consume(':'))
                    value(depth + 1, key in metadata)
                    whitespace()
                    if (consume('}')) return
                    requireValid(consume(','))
                }
            }
            '[' -> {
                index++; whitespace()
                if (consume(']')) return
                while (true) {
                    value(depth + 1); whitespace()
                    if (consume(']')) return
                    requireValid(consume(','))
                }
            }
            '"' -> string()
            't' -> literal("true")
            'f' -> literal("false")
            'n' -> literal("null")
            else -> requireValid(number.matches(numberToken()))
        }
    }

    private fun string(): String {
        val start = index
        requireValid(consume('"'))
        while (index < text.length) {
            val char = text[index++]
            if (char == '"') return JSONTokener(text.substring(start, index)).nextValue() as String
            requireValid(char.code >= 0x20)
            if (char == '\\') {
                val escape = text.getOrNull(index++)
                if (escape == 'u') repeat(4) {
                    val hex = text.getOrNull(index++)
                    requireValid(hex != null && (hex in '0'..'9' || hex in 'a'..'f' || hex in 'A'..'F'))
                } else requireValid(escape in listOf('"', '\\', '/', 'b', 'f', 'n', 'r', 't'))
            }
        }
        throw IllegalArgumentException("Invalid JSON")
    }

    private fun numberToken(): String {
        val start = index
        while (index < text.length && text[index] !in " \t\r\n,]}") index++
        return text.substring(start, index)
    }
    private fun literal(value: String) {
        requireValid(text.startsWith(value, index)); index += value.length
    }
    private fun consume(char: Char): Boolean = (text.getOrNull(index) == char).also { if (it) index++ }
    private fun whitespace() { while (index < text.length && text[index] in " \t\r\n") index++ }
    private fun requireValid(value: Boolean) { if (!value) throw IllegalArgumentException("Invalid JSON") }
}
