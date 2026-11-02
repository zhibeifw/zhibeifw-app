package com.zhibeifw.app

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import com.zhibeifw.app.core.PushGuard

enum class Tab { HOME, CATEGORIES, LIBRARY, SEARCH }

/** 页面地址（Navigation Compose 的路由）。课程 ID 可以是中文，拼进路径前先编码。 */
object Routes {
    const val HOME = "home"
    const val CATEGORIES = "categories"
    const val LIBRARY_HUB = "libraryHub"
    const val SEARCH = "search"
    const val RECENT = "recent"
    const val FAVORITES = "favorites"
    const val LIBRARY = "library"
    const val ABOUT = "about"
    fun category(id: String) = "category/${Uri.encode(id)}"
    fun series(id: String) = "series/${Uri.encode(id)}"
    fun libraryCourse(id: String) = "libraryCourse/${Uri.encode(id)}"
    fun seriesIdOf(e: NavBackStackEntry): String? =
        if (e.destination.route == "series/{id}") e.arguments?.getString("id")
            ?.let { Uri.decode(it) } else null
}

/** 页面导航：当前标签和每个标签自己的页面栈（与 iOS Navigator.swift 对应）。 */
class Navigator {
    var tab by mutableStateOf(Tab.HOME)

    /** 各标签的页面栈：页面在时由根视图交进来，页面销毁时收回 */
    var homeNav: NavHostController? = null
    var categoriesNav: NavHostController? = null
    var libraryNav: NavHostController? = null
    var searchNav: NavHostController? = null

    /** 底部导航栏是否显示（关于页不显示）；Snackbar 据此决定要不要给导航栏让位 */
    var bottomNavShown by mutableStateOf(true)
    private val pushGuard = PushGuard()

    /** 当前标签的页面栈 */
    val navController
        get() = when (tab) {
            Tab.HOME -> homeNav; Tab.CATEGORIES -> categoriesNav; Tab.LIBRARY -> libraryNav; Tab.SEARCH -> searchNav
        }

    /** 进一层。连点同一个入口只进一次。 */
    fun push(route: String) {
        if (!pushGuard.allow("$tab-$route")) return
        navController?.navigate(route)
    }

    /** 点底部标签：点的是当前标签就回到这一栏的第一页。 */
    fun selectTab(t: Tab) {
        if (tab == t) navController?.let { nc -> nc.popBackStack(nc.graph.startDestinationId, false) } else tab = t
    }

    /** 当前标签最上面是不是这门课。 */
    fun isShowingSeries(seriesId: String) =
        navController?.currentBackStackEntry?.let { Routes.seriesIdOf(it) } == seriesId
}
