package com.rawlab.android.testing

import androidx.test.platform.app.InstrumentationRegistry

internal object TestTimeouts {
    private fun argMs(name: String, defaultMs: Long): Long =
        InstrumentationRegistry.getArguments().getString(name)?.toLongOrNull() ?: defaultMs

    val importMs: Long get() = argMs("testImportTimeoutMs", 90_000L)
    val operationMs: Long get() = argMs("testOperationTimeoutMs", 90_000L)
}
