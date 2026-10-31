package com.zhibeifw.app.ui

import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.design.ts

// 菜单与课程简介弹窗：用系统（Material）自带的（LATFORM-DIFFERENCES A16）。

data class MenuItem(
    val title: String,
    val icon: String? = null,
    val destructive: Boolean = false,
    val checked: Boolean? = null,
    val action: () -> Unit
)

data class SheetSpec(val title: String, val category: String?, val body: String)

/**
 * 系统下拉菜单：点 [anchor] 弹出，挂在它下面（放不下系统自动往上翻）。组之间用分隔线，破坏性项红色，可勾选的项前面打对勾。
 * 图标沿用项目里的（Android 系统没有自带图标库）。
 */
@Composable
fun NativeMenu(
    items: () -> List<List<MenuItem>>,
    modifier: Modifier = Modifier,
    anchor: @Composable (open: () -> Unit) -> Unit
) {
    var open by remember { mutableStateOf(false) }
    // 打开时把选项记下来：关闭动画还在播时内容不能先清空，否则菜单高度突然塌掉，看着一卡一卡的
    var groups by remember { mutableStateOf<List<List<MenuItem>>>(emptyList()) }
    Box(modifier) {
        anchor { groups = items(); open = true }
        // 底色用我们的令牌（App 没设 Material 主题色，默认会带一层淡紫）
        DropdownMenu(open, onDismissRequest = { open = false }, containerColor = C.background()) {
            val checkable = groups.flatten().any { it.checked != null }
            groups.forEachIndexed { gi, group ->
                if (gi > 0) HorizontalDivider()
                group.forEach { item ->
                    val col = if (item.destructive) C.danger() else C.labelPrimary()
                    DropdownMenuItem(
                        text = { Text(item.title, style = S.menuItem.ts(col)) },
                        onClick = { open = false; item.action() },
                        leadingIcon = when {
                            checkable -> ({
                                Box(Modifier.alpha(if (item.checked == true) 1f else 0f)) {
                                    ZIcon(
                                        "checkmark",
                                        Tok.Menu.iconSize.d,
                                        C.labelPrimary()
                                    )
                                }
                            })

                            item.icon != null -> ({ ZIcon(item.icon, Tok.Menu.iconSize.d, col) })
                            else -> null
                        },
                        modifier = Modifier.semantics {
                            contentDescription =
                                if (item.checked == true) "${item.title}，已选" else item.title
                        },
                    )
                }
            }
        }
    }
}

/** 课程简介：系统底部弹窗（ModalBottomSheet），先半屏、可拉到全屏，下拉或点外面关闭。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DescriptionSheetLayer(model: AppModel) {
    val spec = model.sheet ?: return
    val state = rememberModalBottomSheetState()
    ModalBottomSheet(
        onDismissRequest = { model.sheet = null },
        sheetState = state,
        containerColor = C.background()
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = Tok.Space.pageMargin.d).navigationBarsPadding()
                .padding(bottom = Tok.Space.pageMargin.d)
        ) {
            Txt(spec.title, S.sheetSeriesTitle, C.labelPrimary())
            if (spec.category != null) {
                Spacer(Modifier.height(CP.Sheet.categoryTop.d)); Txt(
                    spec.category,
                    S.body,
                    C.labelSecondary()
                )
            }
            Spacer(Modifier.height(CP.Sheet.bodyTop.d))
            SelectionContainer { Txt(spec.body, S.sheetBody, C.labelPrimary()) }
        }
    }
}
