package com.zhibeifw.app

import android.app.Application
import android.content.Context
import androidx.test.runner.AndroidJUnitRunner

/** 组件回归独立于主 App 启动，避免后台目录刷新和下载对账干扰测试中的系统任务。 */
class RegressionTestRunner : AndroidJUnitRunner() {
    override fun newApplication(cl: ClassLoader?, className: String?, context: Context?): Application =
        super.newApplication(cl, Application::class.java.name, context)
}
