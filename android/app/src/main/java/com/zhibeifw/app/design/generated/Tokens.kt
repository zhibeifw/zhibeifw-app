// 自动生成，不要手改。来源：doc/design-tokens.json，生成脚本：tools/gen_design.py
package com.zhibeifw.app.design.generated

import com.zhibeifw.app.design.ZColor
import com.zhibeifw.app.design.ZTextStyle

object Tok {
    object Color {
        val background = ZColor(light = 0xFFFFFFFF, dark = 0xFF000000)
        val backgroundSecondary = ZColor(light = 0xFFF2F2F7, dark = 0xFF1C1C1E)
        val labelPrimary = ZColor(light = 0xFF000000, dark = 0xFFFFFFFF)
        val labelSecondary = ZColor(light = 0xFF6C6C70, dark = 0xFF98989F)
        val labelTertiary = ZColor(light = 0xFF8E8E93, dark = 0xFF8E8E93)
        val separator = ZColor(light = 0xFFE8E8E8, dark = 0xFF38383B)
        val grabber = ZColor(light = 0xFFC6C6C8, dark = 0xFF48484A)
        val progressTrack = ZColor(light = 0xFFE5E5EA, dark = 0xFF3A3A3C)
        val progressFill = ZColor(light = 0xFF3A3A3C, dark = 0xFFE5E5EA)
        val menuSurface = ZColor(light = 0xF7FAFAFC, dark = 0xF72C2C2E)
        val menuBand = ZColor(light = 0xFFEFEFF4, dark = 0x80000000)
        val danger = ZColor(light = 0xFFE5342B, dark = 0xFFFF453A)
        val iconDisabled = ZColor(light = 0xFFC6C6C8, dark = 0xFF48484A)
        val onColor = ZColor(light = 0xFFFFFFFF, dark = 0xFFFFFFFF)
        val glassSurface = ZColor(light = 0xD1FFFFFF, dark = 0xC72C2C2E)
        val glassBorder = ZColor(light = 0x14000000, dark = 0x24FFFFFF)
        val navDrop = ZColor(light = 0x0F000000, dark = 0x1FFFFFFF)
        object HighContrast {
            val labelSecondary = ZColor(light = 0xFF3A3A3C, dark = 0xFFD1D1D6)
            val labelTertiary = ZColor(light = 0xFF5C5C61, dark = 0xFFAEAEB2)
            val separator = ZColor(light = 0xFFC6C6C8, dark = 0xFF545458)
            val iconDisabled = ZColor(light = 0xFF8E8E93, dark = 0xFF636366)
            val danger = ZColor(light = 0xFFD70015, dark = 0xFFFF6961)
        }
    }
    object ContentPalette {
        val colors: List<ZColor> = listOf(ZColor.both(0xFFD9691F), ZColor.both(0xFF3D7EBF), ZColor.both(0xFF6B4FA0), ZColor.both(0xFFD65C7A), ZColor.both(0xFF3F8F8F), ZColor.both(0xFF7A8B3C), ZColor.both(0xFF3F8F6B), ZColor.both(0xFF7A3B36))
        val names: List<String> = listOf("橙", "蓝", "紫", "粉红", "青", "橄榄", "绿", "褐红")
        val categoryExtraColors: List<ZColor> = listOf(ZColor.both(0xFFC2453A), ZColor.both(0xFFB0761C), ZColor.both(0xFFA3468E), ZColor.both(0xFF4A56A6), ZColor.both(0xFF5A6B7D), ZColor.both(0xFF3D7A3D), ZColor.both(0xFF8A5A3A), ZColor.both(0xFF2A86A6), ZColor.both(0xFF8E3A5E), ZColor.both(0xFF4A4F57))
        val categoryExtraNames: List<String> = listOf("朱红", "琥珀", "品红", "靛蓝", "石板灰", "森林绿", "可可", "湖蓝", "酒红", "炭灰")
    }
    object Font {
        object Family {
            const val ios: String = "系统字体（San Francisco + 苹方），不打包"
            const val android: String = "Noto Sans SC Regular / Bold（assets/fonts/，打包）"
        }
        object Style {
            val pageTitle = ZTextStyle(size = 34f, weight = 700, lineHeight = 41f)
            val sectionTitle = ZTextStyle(size = 20f, weight = 600, lineHeight = 25f)
            val navTitle = ZTextStyle(size = 17f, weight = 600, lineHeight = 22f)
            val listRowTitle = ZTextStyle(size = 17f, weight = 600, lineHeight = 22f)
            val cardTitle = ZTextStyle(size = 15f, weight = 600, lineHeight = 20f)
            val buttonText = ZTextStyle(size = 15f, weight = 600, lineHeight = 20f)
            val tileText = ZTextStyle(size = 17f, weight = 700, lineHeight = 22f)
            val body = ZTextStyle(size = 17f, weight = 400, lineHeight = 22f)
            val caption = ZTextStyle(size = 13f, weight = 400, lineHeight = 18f)
            val menuItem = ZTextStyle(size = 17f, weight = 400, lineHeight = 22f)
            object NavLabel {
                const val size: Float = 12f
                const val weightSelected: Float = 700f
                const val weightNormal: Float = 500f
                const val lineHeight: Float = 14f
                const val maxScale: Float = 1.15f
            }
            val seriesTitle = ZTextStyle(size = 22f, weight = 700, lineHeight = 28f)
            val playerTitle = ZTextStyle(size = 22f, weight = 700, lineHeight = 28f)
            val aboutName = ZTextStyle(size = 24f, weight = 700, lineHeight = 30f)
            val buttonLarge = ZTextStyle(size = 17f, weight = 600, lineHeight = 22f)
            val bannerText = ZTextStyle(size = 15f, weight = 400, lineHeight = 20f)
            val bannerAction = ZTextStyle(size = 15f, weight = 600, lineHeight = 20f)
            val description = ZTextStyle(size = 15f, weight = 400, lineHeight = 20f)
            val moreLink = ZTextStyle(size = 15f, weight = 600, lineHeight = 20f)
            val captionStrong = ZTextStyle(size = 13f, weight = 600, lineHeight = 18f)
            val rateChip = ZTextStyle(size = 17f, weight = 400, lineHeight = 22f)
            val rateChipSelected = ZTextStyle(size = 19f, weight = 600, lineHeight = 24f)
            val rateLabel = ZTextStyle(size = 17f, weight = 600, lineHeight = 22f)
            val sheetSeriesTitle = ZTextStyle(size = 28f, weight = 700, lineHeight = 34f)
            val sheetBody = ZTextStyle(size = 17f, weight = 400, lineHeight = 26f)
            val seekNumber = ZTextStyle(size = 11f, weight = 700, lineHeight = 13f)
        }
        const val largeTextScale: Float = 1.6f
        object MaxScale {
            const val navTitle: Float = 1.3f
            const val button: Float = 1.3f
            const val capsule: Float = 1.35f
            const val rateLabel: Float = 1.3f
            const val rateChip: Float = 1.2f
        }
        object MinScale {
            const val buttonLarge: Float = 0.8f
        }
    }
    object Space {
        val scale: List<Float> = listOf(4f, 8f, 12f, 16f, 20f, 28f, 36f)
        const val pageMargin: Float = 20f
        const val pageMarginTablet: Float = 32f
        const val sectionGap: Float = 28f
        const val sectionTitleToRow: Float = 8f
        const val cardGap: Float = 12f
        const val cardImageToTitle: Float = 8f
        const val tabletBreakpoint: Float = 600f
        object MinTouchTarget {
            const val ios: Float = 44f
            const val android: Float = 48f
        }
        const val textGap: Float = 2f
        const val searchBarInset: Float = 8f
    }
    object Radius {
        const val cardLarge: Float = 14f
        const val cardSmall: Float = 12f
        const val tile: Float = 12f
        const val thumbnail: Float = 8f
        const val menu: Float = 14f
        const val ratePanel: Float = 26f
        const val pill: String = "full"
    }
    object Line {
        const val separator: String = "1pt/1dp 取整到整数物理像素（3 倍屏 3 像素），颜色 separator；不要用 0.5 或 hairline"
    }
    object Card {
        const val largeWidthPhone: String = "W - 68"
        const val smallWidthPhone: String = "floor((W - 32) / 1.5)"
        const val largeWidthTablet: Float = 360f
        const val smallWidthTablet: Float = 200f
        const val aspect: String = "16:9"
        const val seriesRowCoverWidth: String = "round(W * 0.44)"
        object TileColumns {
            const val phone: Float = 2f
            const val tablet: Float = 4f
        }
        const val seriesRowMaxWidth: Float = 640f
    }
    object Nav {
        const val capsuleHeight: Float = 52f
        const val menuHeight: Float = 66f
        const val collapsedHeight: Float = 44f
        const val collapsedGap: Float = 8f
        const val stackGap: Float = 14f
        const val sideMargin: Float = 16f
        const val bottomMargin: Float = 8f
        const val tabletMaxWidth: Float = 560f
        const val iconSize: Float = 26f
        const val dropInset: Float = 6f
        const val collapseMs: Float = 180f
        const val collapseEasing: String = "easeOut(quad)"
        object CollapseRule {
            const val downAccumulate: Float = 24f
            const val leaveTopAfter: Float = 60f
            const val backToTopWithin: Float = 8f
        }
        const val iconGlyph: Float = 24f
        const val androidBarHeight: Float = 80f
    }
    object Menu {
        const val width: Float = 252f
        const val widthCheckable: Float = 296f
        const val itemHeight: Float = 52f
        const val groupBand: Float = 8f
        const val anchorGap: Float = 6f
        const val itemPaddingH: Float = 16f
        const val iconGap: Float = 12f
        const val iconSize: Float = 22f
        const val dim: Boolean = false
        object Shadow {
            const val opacity: Float = 0.2f
            const val radius: Float = 24f
            const val offsetY: Float = 8f
            const val androidElevation: Float = 12f
        }
        const val borderWidth: Float = 0.5f
        const val checkIconScale: Float = 0.8f
    }
    object RatePicker {
        val rates: List<Float> = listOf(0.8f, 1f, 1.3f, 1.5f, 1.8f, 2f)
        const val sideMargin: Float = 12f
        const val paddingH: Float = 22f
        const val paddingV: Float = 14f
        const val anchorGap: Float = 8f
        const val maxWidth: Float = 520f
        const val chip: Float = 44f
        const val chipSelected: Float = 52f
        const val chipMin: Float = 30f
        const val gapRatio: Float = 0.25f
    }
    object ProgressBar {
        const val height: Float = 6f
        const val heightDragging: Float = 10f
        const val touchHeight: Float = 44f
        const val accessibilityStepSec: Float = 10f
        const val thumb: Float = 16f
    }
    object PageHeader {
        const val rowHeight: Float = 52f
        const val backButtonVisual: Float = 36f
        const val backButtonTouch: Float = 44f
        const val iconSize: Float = 26f
        const val androidLargeExpanded: Float = 112f
    }
    object Player {
        const val portraitMaxWidth: Float = 600f
        const val seekBackSeconds: Float = 15f
        const val seekForwardSeconds: Float = 30f
        const val dragStart: Float = 12f
    }
    object Sheet {
        const val openMs: Float = 280f
        const val closeMs: Float = 220f
        const val dismissDistance: Float = 110f
        const val dismissVelocity: Float = 0.9f
        const val maxWidth: Float = 600f
        const val scrimOpacity: Float = 0.35f
    }
    object GlassShadow {
        const val opacity: Float = 0.1f
        const val radius: Float = 10f
        const val offsetY: Float = 3f
        const val androidElevation: Float = 3f
    }
    object Component {
        object PageTitle {
            const val topGap: Float = 8f
            const val bottomGap: Float = 12f
            const val infoIcon: Float = 28f
        }
        object QuickPill {
            const val height: Float = 40f
            const val gap: Float = 8f
            const val bottomGap: Float = 16f
        }
        object Banner {
            const val height: Float = 44f
            const val radius: Float = 12f
            const val paddingH: Float = 16f
            const val topGap: Float = 0f
            const val bottomGap: Float = 16f
        }
        object UpdatingHint {
            const val indicatorSize: Float = 14f
            const val strokeWidth: Float = 2f
            const val gap: Float = 6f
        }
        object RetryButton {
            const val height: Float = 44f
            const val paddingH: Float = 28f
            const val topGap: Float = 16f
        }
        object SectionTitle {
            const val arrowGap: Float = 4f
            const val arrowSize: Float = 15f
            const val minTouch: Float = 44f
            const val inlineArrowScale: Float = 0.8f
        }
        object SearchField {
            const val height: Float = 44f
            const val iconSize: Float = 18f
            const val iconGap: Float = 8f
            const val paddingH: Float = 14f
            const val topGap: Float = 12f
            const val cancelGap: Float = 12f
            const val maxLength: Float = 30f
        }
        object Tile {
            const val height: Float = 96f
            const val iconSize: Float = 26f
            const val iconOpacity: Float = 0.6f
            const val padding: Float = 14f
            const val gap: Float = 12f
            const val topGap: Float = 16f
        }
        object ListRow {
            const val minHeight: Float = 72f
            const val thumbWidth: Float = 96f
            const val thumbHeight: Float = 54f
            const val gap: Float = 12f
            const val paddingV: Float = 9f
        }
        object SeriesRow {
            const val coverRatio: Float = 0.44f
            const val gap: Float = 12f
            const val textGap: Float = 12f
            const val metaGap: Float = 4f
        }
        object RecentRow {
            const val thumbWidth: Float = 112f
            const val thumbHeight: Float = 63f
            const val gap: Float = 12f
            const val paddingV: Float = 14f
            const val actionsTop: Float = 8f
        }
        object EpisodeRow {
            const val paddingV: Float = 12f
            const val titleToActions: Float = 8f
            const val pillHeight: Float = 44f
            const val pillPaddingH: Float = 14f
            const val pillIconTouch: Float = 52f
            const val pillGap: Float = 8f
            const val playIcon: Float = 17f
            const val replayIcon: Float = 20f
            const val miniBarWidth: Float = 34f
            const val miniBarHeight: Float = 4f
            const val statusGap: Float = 10f
            const val statusIcon: Float = 18f
            const val ring: Float = 22f
            const val ringLine: Float = 2.5f
            const val moreIcon: Float = 20f
            const val moreTouch: Float = 44f
            const val ringMinArc: Float = 0.02f
            const val gaugeNative: Float = 52f
            const val ringIcon: Float = 11f
        }
        object SeriesHeader {
            const val coverMargin: Float = 36f
            const val coverRadius: Float = 12f
            const val coverTop: Float = 8f
            const val titleTop: Float = 16f
            const val buttonsTop: Float = 16f
            const val buttonHeight: Float = 50f
            const val buttonGap: Float = 12f
            const val buttonIcon: Float = 18f
            const val buttonIconGap: Float = 8f
            const val descTop: Float = 16f
            const val descLines: Float = 3f
            const val moreFade: Float = 40f
            const val infoTop: Float = 10f
            const val separatorTop: Float = 20f
            const val sectionTop: Float = 20f
            const val sectionBottom: Float = 4f
            object Shadow {
                const val opacity: Float = 0.18f
                const val radius: Float = 30f
                const val offsetY: Float = 12f
                const val androidElevation: Float = 16f
            }
        }
        object Capsule {
            const val thumb: Float = 36f
            const val thumbRadius: Float = 8f
            const val paddingH: Float = 8f
            const val textGap: Float = 10f
            const val playIcon: Float = 22f
            const val forwardIcon: Float = 30f
            const val iconTouch: Float = 44f
            const val emptyIcon: Float = 20f
            const val thumbInset: Float = 4f
        }
        object NavMenu {
            const val labelGap: Float = 2f
        }
        object About {
            const val logoWidth: Float = 150f
            const val logoTop: Float = 36f
            const val nameTop: Float = 16f
            const val rowsTop: Float = 40f
            const val rowMinHeight: Float = 56f
            const val footerTop: Float = 40f
            const val footerGap: Float = 4f
        }
        object Player {
            const val grabberWidth: Float = 36f
            const val grabberHeight: Float = 5f
            const val grabberTop: Float = 8f
            const val coverSideMargin: Float = 20f
            const val coverMinPad: Float = 24f
            const val coverRadius: Float = 14f
            const val coverMinRatio: Float = 0.6f
            const val bottomPad: Float = 32f
            const val titleToBar: Float = 28f
            const val barToControls: Float = 36f
            const val controlsSideMargin: Float = 22f
            const val timeTop: Float = 8f
            const val seekIcon: Float = 40f
            const val playIcon: Float = 52f
            const val moonIcon: Float = 24f
            const val moreButton: Float = 36f
            const val moreIcon: Float = 20f
            const val courseGap: Float = 2f
            const val tabletPortraitMaxWidth: Float = 640f
            object LandscapeTablet {
                const val cover: Float = 500f
                const val right: Float = 420f
                const val gap: Float = 64f
                const val side: Float = 56f
            }
            object LandscapePhone {
                const val cover: Float = 330f
                const val right: Float = 340f
                const val gap: Float = 44f
                const val side: Float = 60f
                const val coverHeightInset: Float = 48f
                const val tightGap: Float = 18f
            }
            const val dismissDistance: Float = 140f
            object CoverShadow {
                const val opacity: Float = 0.18f
                const val radius: Float = 30f
                const val offsetY: Float = 12f
                const val androidElevation: Float = 16f
            }
            const val courseMinHeight: Float = 26f
        }
        object Sheet {
            const val topExposed: Float = 48f
            const val radius: Float = 14f
            const val closeButton: Float = 30f
            const val headerHeight: Float = 56f
            const val contentTop: Float = 8f
            const val categoryTop: Float = 4f
            const val bodyTop: Float = 16f
            const val closeIconScale: Float = 0.55f
        }
        object EmptyState {
            const val paddingH: Float = 40f
        }
        object Splash {
            const val logoWidth: Float = 120f
            const val androidLogoWidth: Float = 96f
        }
        object Init {
            const val spinnerGap: Float = 16f
            const val lineGap: Float = 8f
        }
    }
    object Motion {
        const val pressedOpacity: Float = 0.7f
        object SpringBouncy {
            const val response: Float = 0.5f
            const val bounce: Float = 0.3f
            const val stiffness: Float = 157.9f
            const val damping: Float = 17.6f
            const val mass: Float = 1f
            const val dampingRatio: Float = 0.7f
        }
        object NavDrop {
            const val stretchX: Float = 1.35f
            const val stretchY: Float = 0.88f
            const val stretchInMs: Float = 110f
            const val iconPressScale: Float = 0.86f
            const val reduceMotionMs: Float = 150f
        }
        const val fadeMs: Float = 150f
        const val pressMs: Float = 120f
        const val settleMs: Float = 300f
        const val menuScaleFrom: Float = 0.9f
        object SharedAxis {
            const val distance: Float = 30f
            const val durationMs: Float = 300f
            const val fadeOutMs: Float = 90f
        }
    }
}
