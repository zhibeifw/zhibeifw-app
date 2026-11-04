package com.zhibeifw.app.ui

import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.text.style.TextAlign
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.R
import com.zhibeifw.app.core.UpdateChannel
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.Separator
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.net.NetConfig
import kotlinx.coroutines.launch

/** 关于智悲佛网。居中小标题；Android 官网版末尾多一行“检查更新”。 */
@Composable
fun AboutView(model: AppModel) {
    var clearing by remember { mutableStateOf(false) }
    var checkingRoute by remember { mutableStateOf(false) }
    var checkingUpdate by remember { mutableStateOf(false) }
    // 清除缓存、刷新网络线路的结果显示在那一行右边（Material 列表行的右侧说明文字，和 iOS 一致，不用 Snackbar）
    var clearResult by remember { mutableStateOf<String?>(null) }
    var routeResult by remember { mutableStateOf<String?>(null) }
    var updateResult by remember { mutableStateOf<String?>(null) }
    // 顶部不放标题，只有返回键：下面的 Logo 和“智悲佛网”已经说明这是哪一页
    PageScaffold(model, "", largeTitle = false, centeredTitle = true) {
        item("body") {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                Column(
                    Modifier.widthIn(max = Tok.Player.portraitMaxWidth.d),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Image(
                        painterResource(R.drawable.logo), "智悲佛网 Logo",
                        Modifier.padding(top = CP.About.logoTop.d).width(CP.About.logoWidth.d)
                    )
                    Txt(
                        "智悲佛网",
                        S.aboutName,
                        C.labelPrimary(),
                        Modifier.padding(top = CP.About.nameTop.d)
                            .semantics { heading() }) // 读屏把这一行当作页面标题
                    Column(Modifier.padding(top = CP.About.rowsTop.d)) {
                        Row("联系", value = "hello@zhibeifw.com")
                        Separator(Modifier.padding(horizontal = Tok.Space.pageMargin.d))
                        Row("隐私政策", arrow = true) { model.openExternal(NetConfig.PRIVACY_URL) }
                        Separator(Modifier.padding(horizontal = Tok.Space.pageMargin.d))
                        Row("源代码", arrow = true) { model.openExternal(NetConfig.SOURCE_URL) }
                        Separator(Modifier.padding(horizontal = Tok.Space.pageMargin.d))
                        Row(
                            "清除缓存",
                            value = if (clearing) "正在清除…" else clearResult,
                            result = true
                        ) {
                            if (clearing) return@Row
                            clearing = true
                            model.launch {
                                // 磁盘缓存不设上限，可能有几千个文件：放到后台删，不卡界面
                                val ok = withContext(Dispatchers.IO) { runCatching { model.images.clear() }.getOrDefault(false) }
                                clearing = false
                                clearResult = if (ok) "已清除" else "清除失败"
                            }
                        }
                        Separator(Modifier.padding(horizontal = Tok.Space.pageMargin.d))
                        Row(
                            "刷新网络线路",
                            value = if (checkingRoute) "正在检测…" else routeResult,
                            result = true
                        ) {
                            if (checkingRoute) return@Row
                            checkingRoute = true
                            model.launch {
                                try {
                                    routeResult = model.refreshRoutes()
                                } finally {
                                    checkingRoute = false
                                }
                            }
                        }
                        if (model.channel == UpdateChannel.SITE) {
                            Separator(Modifier.padding(horizontal = Tok.Space.pageMargin.d))
                            Row(
                                "检查更新",
                                value = if (checkingUpdate) "正在检查…" else updateResult,
                                result = true
                            ) {
                                if (checkingUpdate) return@Row
                                checkingUpdate = true
                                updateResult = null
                                model.launch {
                                    try {
                                        updateResult = model.upgrade.check(manual = true)
                                    } finally {
                                        checkingUpdate = false
                                    }
                                }
                            }
                        }
                    }
                    // 页脚
                    Column(
                        Modifier.padding(top = CP.About.footerTop.d),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(CP.About.footerGap.d)
                    ) {
                        Txt("智悲佛网 版权所有", S.caption, C.labelSecondary())
                        Txt(
                            "版本 " + model.versionName,
                            S.caption,
                            C.labelTertiary()
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun Row(
    title: String,
    value: String? = null,
    result: Boolean = false,
    arrow: Boolean = false,
    onClick: (() -> Unit)? = null
) {
    val mod = Modifier.fillMaxWidth().heightIn(min = CP.About.rowMinHeight.d)
        .let { if (onClick != null) it.pressable(onClick = onClick) else it }
        .padding(horizontal = Tok.Space.pageMargin.d)
    androidx.compose.foundation.layout.Row(
        mod,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tok.Space.scale[1].d)
    ) {
        Txt(title, S.body, C.labelPrimary())
        if (result) {
            // 操作结果：占满中间、靠右，箭头贴在行尾和其他行对齐；读屏自动念出（liveRegion）
            Txt(
                value ?: "",
                S.body,
                C.labelSecondary(),
                Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite },
                align = TextAlign.End
            )
        } else {
            Spacer(Modifier.weight(1f))
            if (value != null) SelectionContainer {
                Txt(
                    value,
                    S.body,
                    C.labelSecondary()
                )
            } // 长按由系统完成选择与复制
        }
        if (arrow) ZIcon("chevron-forward", CP.SectionTitle.arrowSize.d, C.labelTertiary())
    }
}
