package com.rawlab.android

import android.app.Application
import com.rawlab.android.i18n.AppStrings

/** 进程入口：在任何界面、ViewModel 或测试运行之前，把界面文字所需的 Application 交给 AppStrings */
class RawLabApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppStrings.initialize(this)
    }
}
