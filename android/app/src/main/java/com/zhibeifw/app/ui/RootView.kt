package com.zhibeifw.app.ui

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.Phase
import com.zhibeifw.app.R
import com.zhibeifw.app.Routes
import com.zhibeifw.app.Tab
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import kotlinx.coroutines.launch

@Composable
fun RootView(model: AppModel) {
    Box(Modifier.fillMaxSize().background(C.background())) {
        when (val ph = model.phase) {
            Phase.Launching -> SplashView()
            Phase.DbError -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                EmptyStateView("升级本机数据时出错，你的收听记录和下载都还在。请重启 App 再试；仍然不行请联系我们。")
            }

            is Phase.Initializing -> InitView(model, ph.attempt, ph.failed)
            Phase.Ready -> MainView(model)
        }
        AlertLayer(model)
    }
}

@Composable
fun SplashView() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Image(painterResource(R.drawable.logo), null, Modifier.width(CP.Splash.logoWidth.d))
    }
}

/** 首次初始化：转圈 +“正在准备内容…”；失败后“暂时无法连接”+ 重试 + 刷新网络线路。 */
@Composable
fun InitView(model: AppModel, attempt: Int, failed: Boolean) {
    var refreshing by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxSize().padding(horizontal = CP.EmptyState.paddingH.d),
        verticalArrangement = Arrangement.spacedBy(
            CP.Init.spinnerGap.d,
            Alignment.CenterVertically
        ),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        if (failed) {
            Txt("暂时无法连接", S.body, C.labelSecondary())
            RetryButton("重试") { model.launch { model.runInitialization() } }
            RetryButton(if (refreshing) "正在检测…" else "刷新网络线路") {
                if (refreshing) return@RetryButton
                refreshing = true
                model.launch {
                    model.net.refreshRoutes(); refreshing = false; model.runInitialization()
                }
            }
        } else {
            CircularProgressIndicator(color = C.labelSecondary())
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(CP.Init.lineGap.d)
            ) {
                Txt("正在准备内容…", S.body, C.labelPrimary())
                Txt("第一次使用需要联网，请稍候", S.caption, C.labelSecondary())
                if (attempt >= 2) Txt("正在重新连接（第 $attempt 次）", S.caption, C.labelSecondary())
            }
        }
    }
}

/** 系统弹窗（Android 用 Material 对话框，外观由系统决定）。 */
@Composable
fun AlertLayer(model: AppModel) {
    val a = model.alert
    // 只是告知、不用用户做决定的（没有说明文字、只有一个“好”）：用 Material 的 Snackbar，几秒后自动消失
    val notice = a != null && a.message == null && a.buttons.size == 1 && a.buttons[0].title == "好"
    val snack = remember { SnackbarHostState() }
    // 先把文字记下来再清掉 alert；显示放在另一个以文字为键的协程里，清 alert 不会把它取消
    var pending by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(a) {
        if (a != null && notice) {
            pending = a.title; model.alert = null
        }
    }
    LaunchedEffect(pending) { pending?.let { snack.showSnackbar(it); pending = null } }
    Box(
        Modifier.fillMaxSize().navigationBarsPadding()
            .padding(bottom = (if (model.bottomNavShown) Layout.navReserve else 0f).d),
        contentAlignment = Alignment.BottomCenter
    ) {
        SnackbarHost(snack)
    }
    if (a != null && !notice) {
        val close = { model.alert = null }
        val buttons = a.buttons
        AlertDialog(
            onDismissRequest = close,
            title = { Text(a.title) },
            text = a.message?.let { m -> { Text(m) } },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    buttons.filter { !it.cancel }.forEach { b ->
                        TextButton({ close(); b.action() }) {
                            Text(
                                b.title,
                                color = if (b.destructive) C.danger() else Color.Unspecified
                            )
                        }
                    }
                }
            },
            dismissButton = buttons.firstOrNull { it.cancel }
                ?.let { b -> { TextButton({ close(); b.action() }) { Text(b.title) } } },
        )
    }
    val u = model.updateDialog
    if (u != null) {
        AlertDialog(
            onDismissRequest = { model.remindLater(u.version) },
            title = { Text("发现新版本 ${u.version}") },
            confirmButton = { TextButton({ model.openApk(u.apkPath) }) { Text("立刻更新") } },
            dismissButton = { TextButton({ model.remindLater(u.version) }) { Text("稍后提醒") } },
        )
    }
}

@Composable
fun MainView(model: AppModel) {
    val homeNav = rememberNavController()
    val categoriesNav = rememberNavController()
    val libraryNav = rememberNavController()
    val searchNav = rememberNavController()
    model.homeNav = homeNav
    model.categoriesNav = categoriesNav
    model.libraryNav = libraryNav
    model.searchNav = searchNav
    val homeEntry by homeNav.currentBackStackEntryAsState()
    val categoriesEntry by categoriesNav.currentBackStackEntryAsState()
    val libraryEntry by libraryNav.currentBackStackEntryAsState()
    val searchEntry by searchNav.currentBackStackEntryAsState()
    LaunchedEffect(
        homeEntry?.id,
        categoriesEntry?.id,
        libraryEntry?.id,
        searchEntry?.id,
        model.tab
    ) { model.resetNav() }
    val current = when (model.tab) {
        Tab.HOME -> homeEntry; Tab.CATEGORIES -> categoriesEntry; Tab.LIBRARY -> libraryEntry; Tab.SEARCH -> searchEntry
    }
    val onAbout = current?.destination?.route == Routes.ABOUT
    LaunchedEffect(onAbout) { model.bottomNavShown = !onAbout }

    // 分类、资料库、搜索标签在根页面时，系统返回键回到主页标签
    BackHandler(model.tab != Tab.HOME && model.navController?.previousBackStackEntry == null && !model.playerOpen) {
        model.selectTab(
            Tab.HOME
        )
    }

    Box(Modifier.fillMaxSize()) {
        for ((t, nav, start) in listOf(
            Triple(Tab.HOME, homeNav, Routes.HOME),
            Triple(Tab.CATEGORIES, categoriesNav, Routes.CATEGORIES),
            Triple(Tab.LIBRARY, libraryNav, Routes.LIBRARY_HUB),
            Triple(Tab.SEARCH, searchNav, Routes.SEARCH)
        )) {
            val on = model.tab == t
            Box(
                Modifier.fillMaxSize().zIndex(if (on) 1f else 0f).alpha(if (on) 1f else 0f)
            ) { Stack(model, nav, start, on) }
        }
        if (!onAbout) Box(Modifier.align(Alignment.BottomCenter).zIndex(2f)) { BottomNav(model) }
        Box(Modifier.zIndex(3f)) { PlayerLayer(model) }
        Box(Modifier.zIndex(3f)) { DescriptionSheetLayer(model) }
    }
}

@Composable
private fun Stack(model: AppModel, nav: NavHostController, start: String, active: Boolean) {
    val idArg = listOf(navArgument("id") { type = NavType.StringType })
    fun id(e: NavBackStackEntry) = Uri.decode(e.arguments?.getString("id") ?: "")
    // 不在前台的那个标签页：不接收触摸、读屏也读不到（两个标签页各保留自己的页面栈）
    val hide = if (active) Modifier else Modifier.clearAndSetSemantics { }
    Box(Modifier.fillMaxSize().then(hide)) {
        // 页面切换：Material 动效规范的“横向共享轴”，能看出“进一层 / 退一层”
        val ax = com.zhibeifw.app.design.generated.Tok.Motion.SharedAxis
        val dist = with(LocalDensity.current) { ax.distance.dp.roundToPx() }
        val easing = FastOutSlowInEasing
        val move =
            androidx.compose.animation.core.tween<IntOffset>(ax.durationMs.toInt(), easing = easing)
        val fadeIn = androidx.compose.animation.fadeIn(
            androidx.compose.animation.core.tween(
                ax.durationMs.toInt() - ax.fadeOutMs.toInt(),
                delayMillis = ax.fadeOutMs.toInt(),
                easing = easing
            )
        )
        val fadeOut = androidx.compose.animation.fadeOut(
            androidx.compose.animation.core.tween(
                ax.fadeOutMs.toInt(),
                easing = easing
            )
        )
        NavHost(
            nav, startDestination = start,
            enterTransition = { androidx.compose.animation.slideInHorizontally(move) { dist } + fadeIn },
            exitTransition = { androidx.compose.animation.slideOutHorizontally(move) { -dist } + fadeOut },
            popEnterTransition = { androidx.compose.animation.slideInHorizontally(move) { -dist } + fadeIn },
            popExitTransition = { androidx.compose.animation.slideOutHorizontally(move) { dist } + fadeOut },
        ) {
            composable(Routes.HOME) { HomeView(model) }
            composable(Routes.CATEGORIES) { CategoriesView(model) }
            composable(Routes.LIBRARY_HUB) { LibraryHubView(model) }
            composable(Routes.SEARCH) { SearchView(model) }
            composable("category/{id}", idArg) { CategoryView(model, id(it)) }
            composable("series/{id}", idArg) { SeriesView(model, id(it)) }
            composable(Routes.RECENT) { RecentView(model) }
            composable(Routes.FAVORITES) { FavoritesView(model) }
            composable(Routes.LIBRARY) { LibraryView(model) }
            composable("libraryCourse/{id}", idArg) { LibraryCourseView(model, id(it)) }
            composable(Routes.ABOUT) { AboutView(model) }
        }
        if (!active) Box(
            Modifier.fillMaxSize()
                .pointerInput(Unit) { awaitPointerEventScope { while (true) awaitPointerEvent().changes.forEach { it.consume() } } })
    }
}
