package com.rawlab.android.looks

import com.rawlab.android.settings.LookChoice

// 外观管理界面同时接收可用项和保留的坏记录，不能把坏记录误当成空库。
data class LookLibraryEntries(val looks: List<LookChoice>, val unreadable: List<UnreadableLook>) {
    companion object {
        fun load(library: LookLibrary, builtIns: List<LookChoice> = emptyList()) = LookLibraryEntries(
            builtIns + library.list().map {
                LookChoice(it.id, it.name, managed = true, available = it.available,
                    appearanceUnverified = it.appearanceUnverified, compatibilityMode = it.compatibilityMode)
            }, library.listUnreadable())

        fun removeUnreadable(library: LookLibrary, entry: UnreadableLook, builtIns: List<LookChoice> = emptyList()): LookLibraryEntries {
            library.removeUnreadable(entry)
            return load(library, builtIns)
        }
    }
}
