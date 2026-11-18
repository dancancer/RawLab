package com.rawlab.android.json

import com.fasterxml.jackson.core.JacksonException
import com.fasterxml.jackson.core.JsonFactory
import com.fasterxml.jackson.core.JsonParser
import com.fasterxml.jackson.core.JsonToken
import com.fasterxml.jackson.core.StreamReadConstraints
import com.fasterxml.jackson.core.StreamReadFeature
import org.json.JSONArray
import org.json.JSONObject

private val strictJsonFactory: JsonFactory = JsonFactory.builder()
    .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
    .streamReadConstraints(StreamReadConstraints.builder().maxNestingDepth(64).build())
    .build()

/** 只检查词法与整数元数据；不转换数字，也不为只验证的调用方分配 JSON 树。 */
internal fun validateStrictJSON(text: String, integerKeys: Set<String> = emptySet()) {
    readStrictJSON(text, integerKeys, materialize = false, strictJsonFactory)
}

/** 同一轮严格 token 读取直接填充现有对象，调用方无需再次解析原文。 */
internal fun parseStrictJSONObject(
    text: String,
    integerKeys: Set<String> = emptySet(),
    factory: JsonFactory = strictJsonFactory,
): JSONObject = readStrictJSON(text, integerKeys, materialize = true, factory) as? JSONObject
    ?: throw IllegalArgumentException("Invalid JSON object")

private fun readStrictJSON(text: String, integerKeys: Set<String>, materialize: Boolean, factory: JsonFactory): Any? {
    try {
        factory.createParser(text).use { parser ->
            val first = parser.nextToken() ?: throw IllegalArgumentException("Invalid JSON")
            val value = readValue(parser, first, depth = 0, integerKeys, integerRequired = false, materialize)
            if (parser.nextToken() != null) throw IllegalArgumentException("Invalid JSON")
            return value
        }
    } catch (error: IllegalArgumentException) {
        throw error
    } catch (error: JacksonException) {
        throw IllegalArgumentException("Invalid JSON", error)
    }
}

private fun readValue(
    parser: JsonParser,
    token: JsonToken,
    depth: Int,
    integerKeys: Set<String>,
    integerRequired: Boolean,
    materialize: Boolean,
): Any? {
    if (depth >= 64) throw IllegalArgumentException("Invalid JSON")
    if (integerRequired) {
        if (token != JsonToken.VALUE_NUMBER_INT) throw IllegalArgumentException("Invalid JSON")
        parser.longValue
    }
    return when (token) {
        JsonToken.START_OBJECT -> {
            val value = if (materialize) JSONObject() else null
            while (true) {
                val field = parser.nextToken() ?: throw IllegalArgumentException("Invalid JSON")
                if (field == JsonToken.END_OBJECT) break
                if (field != JsonToken.FIELD_NAME) throw IllegalArgumentException("Invalid JSON")
                val key = parser.currentName()
                val child = parser.nextToken() ?: throw IllegalArgumentException("Invalid JSON")
                val item = readValue(parser, child, depth + 1, integerKeys, key in integerKeys, materialize)
                value?.put(key, item)
            }
            value
        }
        JsonToken.START_ARRAY -> {
            val value = if (materialize) JSONArray() else null
            while (true) {
                val item = parser.nextToken() ?: throw IllegalArgumentException("Invalid JSON")
                if (item == JsonToken.END_ARRAY) break
                val child = readValue(parser, item, depth + 1, integerKeys, integerRequired = false, materialize)
                value?.put(child)
            }
            value
        }
        JsonToken.VALUE_STRING -> if (materialize) parser.text else { parser.finishToken(); null }
        JsonToken.VALUE_NUMBER_INT,
        JsonToken.VALUE_NUMBER_FLOAT -> if (materialize) parser.numberValue else { parser.finishToken(); null }
        JsonToken.VALUE_TRUE -> if (materialize) true else null
        JsonToken.VALUE_FALSE -> if (materialize) false else null
        JsonToken.VALUE_NULL -> if (materialize) JSONObject.NULL else null
        else -> throw IllegalArgumentException("Invalid JSON")
    }
}
