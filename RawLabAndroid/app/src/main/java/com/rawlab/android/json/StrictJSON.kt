package com.rawlab.android.json

import com.fasterxml.jackson.core.JacksonException
import com.fasterxml.jackson.core.JsonFactory
import com.fasterxml.jackson.core.JsonParser
import com.fasterxml.jackson.core.JsonToken
import com.fasterxml.jackson.core.StreamReadConstraints
import com.fasterxml.jackson.core.StreamReadFeature

private val strictJsonFactory: JsonFactory = JsonFactory.builder()
    .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
    .streamReadConstraints(StreamReadConstraints.builder().maxNestingDepth(64).build())
    .build()

/** JSONObject 在 Android 接受宽松语法；持久化记录先检查标准 JSON、重复 key 和整数元数据。 */
internal fun validateStrictJSON(text: String, integerKeys: Set<String> = emptySet()) {
    try {
        strictJsonFactory.createParser(text).use { parser ->
            val first = parser.nextToken() ?: throw IllegalArgumentException("Invalid JSON")
            validateValue(parser, first, depth = 0, integerKeys = integerKeys, integerRequired = false)
            if (parser.nextToken() != null) throw IllegalArgumentException("Invalid JSON")
        }
    } catch (error: IllegalArgumentException) {
        throw error
    } catch (error: JacksonException) {
        throw IllegalArgumentException("Invalid JSON", error)
    }
}

private fun validateValue(
    parser: JsonParser,
    token: JsonToken,
    depth: Int,
    integerKeys: Set<String>,
    integerRequired: Boolean,
) {
    if (depth >= 64) throw IllegalArgumentException("Invalid JSON")
    if (integerRequired) {
        if (token != JsonToken.VALUE_NUMBER_INT) throw IllegalArgumentException("Invalid JSON")
        parser.longValue
        return
    }
    when (token) {
        JsonToken.START_OBJECT -> {
            while (true) {
                val field = parser.nextToken() ?: throw IllegalArgumentException("Invalid JSON")
                if (field == JsonToken.END_OBJECT) return
                if (field != JsonToken.FIELD_NAME) throw IllegalArgumentException("Invalid JSON")
                val key = parser.currentName()
                val child = parser.nextToken() ?: throw IllegalArgumentException("Invalid JSON")
                validateValue(parser, child, depth + 1, integerKeys, key in integerKeys)
            }
        }
        JsonToken.START_ARRAY -> {
            while (true) {
                val item = parser.nextToken() ?: throw IllegalArgumentException("Invalid JSON")
                if (item == JsonToken.END_ARRAY) return
                validateValue(parser, item, depth + 1, integerKeys, integerRequired = false)
            }
        }
        JsonToken.VALUE_STRING,
        JsonToken.VALUE_NUMBER_INT,
        JsonToken.VALUE_NUMBER_FLOAT -> parser.finishToken()
        JsonToken.VALUE_TRUE,
        JsonToken.VALUE_FALSE,
        JsonToken.VALUE_NULL -> Unit
        else -> throw IllegalArgumentException("Invalid JSON")
    }
}
