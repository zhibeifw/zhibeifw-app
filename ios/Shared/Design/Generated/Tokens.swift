// 自动生成，不要手改。来源：doc/design-tokens.json，生成脚本：tools/gen_design.py
import CoreGraphics

// swiftlint:disable all
enum Tok {
    enum Color {
        static let background = ZColor(light: 0xFFFFFFFF, dark: 0xFF000000)
        static let backgroundSecondary = ZColor(light: 0xFFF2F2F7, dark: 0xFF1C1C1E)
        static let labelPrimary = ZColor(light: 0xFF000000, dark: 0xFFFFFFFF)
        static let labelSecondary = ZColor(light: 0xFF6C6C70, dark: 0xFF98989F)
        static let labelTertiary = ZColor(light: 0xFF8E8E93, dark: 0xFF8E8E93)
        static let separator = ZColor(light: 0xFFE8E8E8, dark: 0xFF38383B)
        static let progressTrack = ZColor(light: 0xFFE5E5EA, dark: 0xFF3A3A3C)
        static let progressFill = ZColor(light: 0xFF3A3A3C, dark: 0xFFE5E5EA)
        static let danger = ZColor(light: 0xFFE5342B, dark: 0xFFFF453A)
        static let iconDisabled = ZColor(light: 0xFFC6C6C8, dark: 0xFF48484A)
        static let onColor = ZColor(light: 0xFFFFFFFF, dark: 0xFFFFFFFF)
        enum HighContrast {
            static let labelSecondary = ZColor(light: 0xFF3A3A3C, dark: 0xFFD1D1D6)
            static let labelTertiary = ZColor(light: 0xFF5C5C61, dark: 0xFFAEAEB2)
            static let separator = ZColor(light: 0xFFC6C6C8, dark: 0xFF545458)
            static let iconDisabled = ZColor(light: 0xFF8E8E93, dark: 0xFF636366)
            static let danger = ZColor(light: 0xFFD70015, dark: 0xFFFF6961)
        }
        static let compactPlayerInfo = ZColor(light: 0xFF626262, dark: 0xFF626262)
    }
    enum ContentPalette {
        static let colors: [ZColor] = [ZColor(both: 0xFFD9691F), ZColor(both: 0xFF3D7EBF), ZColor(both: 0xFF6B4FA0), ZColor(both: 0xFFD65C7A), ZColor(both: 0xFF3F8F8F), ZColor(both: 0xFF7A8B3C), ZColor(both: 0xFF3F8F6B), ZColor(both: 0xFF7A3B36)]
        static let names: [String] = ["橙", "蓝", "紫", "粉红", "青", "橄榄", "绿", "褐红"]
        static let categoryExtraColors: [ZColor] = [ZColor(both: 0xFFC2453A), ZColor(both: 0xFFB0761C), ZColor(both: 0xFFA3468E), ZColor(both: 0xFF4A56A6), ZColor(both: 0xFF5A6B7D), ZColor(both: 0xFF3D7A3D), ZColor(both: 0xFF8A5A3A), ZColor(both: 0xFF2A86A6), ZColor(both: 0xFF8E3A5E), ZColor(both: 0xFF4A4F57)]
        static let categoryExtraNames: [String] = ["朱红", "琥珀", "品红", "靛蓝", "石板灰", "森林绿", "可可", "湖蓝", "酒红", "炭灰"]
    }
    enum Font {
        enum Style {
            static let pageTitle = ZTextStyle(size: 34, weight: 700, lineHeight: 41)
            static let sectionTitle = ZTextStyle(size: 20, weight: 600, lineHeight: 25)
            static let navTitle = ZTextStyle(size: 17, weight: 600, lineHeight: 22)
            static let listRowTitle = ZTextStyle(size: 17, weight: 600, lineHeight: 22)
            static let cardTitle = ZTextStyle(size: 15, weight: 600, lineHeight: 20)
            static let buttonText = ZTextStyle(size: 15, weight: 600, lineHeight: 20)
            static let tileText = ZTextStyle(size: 17, weight: 700, lineHeight: 22)
            static let body = ZTextStyle(size: 17, weight: 400, lineHeight: 22)
            static let caption = ZTextStyle(size: 13, weight: 400, lineHeight: 18)
            static let menuItem = ZTextStyle(size: 17, weight: 400, lineHeight: 22)
            enum NavLabel {
                static let size: CGFloat = 12
                static let weightNormal: CGFloat = 500
                static let lineHeight: CGFloat = 14
            }
            static let seriesTitle = ZTextStyle(size: 22, weight: 700, lineHeight: 28)
            static let playerTitle = ZTextStyle(size: 22, weight: 700, lineHeight: 28)
            static let aboutName = ZTextStyle(size: 24, weight: 700, lineHeight: 30)
            static let buttonLarge = ZTextStyle(size: 17, weight: 600, lineHeight: 22)
            static let bannerText = ZTextStyle(size: 15, weight: 400, lineHeight: 20)
            static let bannerAction = ZTextStyle(size: 15, weight: 600, lineHeight: 20)
            static let description = ZTextStyle(size: 15, weight: 400, lineHeight: 20)
            static let moreLink = ZTextStyle(size: 15, weight: 600, lineHeight: 20)
            static let captionStrong = ZTextStyle(size: 13, weight: 600, lineHeight: 18)
            static let rateLabel = ZTextStyle(size: 17, weight: 600, lineHeight: 22)
            static let sheetSeriesTitle = ZTextStyle(size: 28, weight: 700, lineHeight: 34)
            static let sheetBody = ZTextStyle(size: 17, weight: 400, lineHeight: 26)
        }
        static let largeTextScale: CGFloat = 1.6
        enum MaxScale {
            static let navTitle: CGFloat = 1.3
            static let capsule: CGFloat = 1.35
            static let rateLabel: CGFloat = 1.3
        }
        enum MinScale {
            static let buttonLarge: CGFloat = 0.8
        }
    }
    enum Space {
        static let scale: [CGFloat] = [4, 8, 12, 16, 20, 28, 36]
        static let pageMargin: CGFloat = 20
        static let pageMarginTablet: CGFloat = 32
        static let sectionGap: CGFloat = 28
        static let sectionTitleToRow: CGFloat = 8
        static let cardGap: CGFloat = 12
        static let cardImageToTitle: CGFloat = 8
        static let tabletBreakpoint: CGFloat = 600
        enum MinTouchTarget {
            static let ios: CGFloat = 44
            static let android: CGFloat = 48
        }
        static let textGap: CGFloat = 2
        static let searchBarInset: CGFloat = 8
    }
    enum Radius {
        static let cardLarge: CGFloat = 14
        static let cardSmall: CGFloat = 12
        static let tile: CGFloat = 12
        static let thumbnail: CGFloat = 8
    }
    enum Card {
        static let largeWidthPhone = "W - 68"
        static let smallWidthPhone = "floor((W - 32) / 1.5)"
        static let largePerScreenTabletPortrait: CGFloat = 2.2
        static let largePerScreenTabletLandscape: CGFloat = 3.2
        static let smallPerScreenTabletPortrait: CGFloat = 3.5
        static let smallPerScreenTabletLandscape: CGFloat = 4.5
        static let aspect = "16:9"
        static let seriesRowCoverWidth = "round(W * 0.44)"
        enum TileColumns {
            static let phone: CGFloat = 2
            static let tablet: CGFloat = 4
        }
        static let seriesRowMaxWidth: CGFloat = 640
    }
    enum Nav {
        static let capsuleHeight: CGFloat = 52
        static let collapsedHeight: CGFloat = 44
        static let sideMargin: CGFloat = 16
        static let bottomMargin: CGFloat = 8
        static let iconGlyph: CGFloat = 24
        static let androidBarHeight: CGFloat = 80
    }
    enum Menu {
        static let iconSize: CGFloat = 22
    }
    enum RatePicker {
        static let rates: [CGFloat] = [0.8, 1, 1.3, 1.5, 1.8, 2]
    }
    enum ProgressBar {
        static let height: CGFloat = 6
        static let touchHeight: CGFloat = 44
        static let thumb: CGFloat = 16
    }
    enum PageHeader {
        static let rowHeight: CGFloat = 52
        static let iconSize: CGFloat = 26
        static let androidLargeExpanded: CGFloat = 112
    }
    enum Player {
        static let portraitMaxWidth: CGFloat = 600
        static let seekBackSeconds: CGFloat = 15
        static let seekForwardSeconds: CGFloat = 30
    }
    enum GlassShadow {
        static let androidElevation: CGFloat = 3
    }
    enum Component {
        enum PageTitle {
            static let topGap: CGFloat = 8
            static let bottomGap: CGFloat = 12
        }
        enum QuickPill {
            static let height: CGFloat = 40
            static let gap: CGFloat = 8
            static let bottomGap: CGFloat = 16
        }
        enum Banner {
            static let height: CGFloat = 44
            static let radius: CGFloat = 12
            static let paddingH: CGFloat = 16
            static let topGap: CGFloat = 0
            static let bottomGap: CGFloat = 16
        }
        enum UpdatingHint {
            static let indicatorSize: CGFloat = 14
            static let strokeWidth: CGFloat = 2
            static let gap: CGFloat = 6
        }
        enum RetryButton {
            static let height: CGFloat = 44
            static let paddingH: CGFloat = 28
            static let topGap: CGFloat = 16
        }
        enum SectionTitle {
            static let arrowGap: CGFloat = 4
            static let arrowSize: CGFloat = 15
            static let minTouch: CGFloat = 44
            static let inlineArrowScale: CGFloat = 0.8
        }
        enum SearchField {
            static let height: CGFloat = 44
            static let iconSize: CGFloat = 18
            static let paddingH: CGFloat = 14
            static let topGap: CGFloat = 12
            static let cancelGap: CGFloat = 12
            static let maxLength: CGFloat = 30
        }
        enum Tile {
            static let height: CGFloat = 96
            static let iconSize: CGFloat = 26
            static let iconOpacity: CGFloat = 0.6
            static let padding: CGFloat = 14
            static let gap: CGFloat = 12
            static let topGap: CGFloat = 16
        }
        enum ListRow {
            static let minHeight: CGFloat = 72
            static let thumbWidth: CGFloat = 96
            static let thumbHeight: CGFloat = 54
            static let gap: CGFloat = 12
            static let paddingV: CGFloat = 9
        }
        enum SeriesRow {
            static let coverRatio: CGFloat = 0.44
            static let gap: CGFloat = 12
            static let textGap: CGFloat = 12
            static let metaGap: CGFloat = 4
        }
        enum RecentRow {
            static let thumbWidth: CGFloat = 112
            static let thumbHeight: CGFloat = 63
            static let gap: CGFloat = 12
            static let paddingV: CGFloat = 14
            static let actionsTop: CGFloat = 8
        }
        enum EpisodeRow {
            static let paddingV: CGFloat = 12
            static let titleToActions: CGFloat = 8
            static let pillHeight: CGFloat = 44
            static let pillPaddingH: CGFloat = 14
            static let pillIconTouch: CGFloat = 52
            static let pillGap: CGFloat = 8
            static let playIcon: CGFloat = 17
            static let replayIcon: CGFloat = 20
            static let miniBarWidth: CGFloat = 34
            static let miniBarHeight: CGFloat = 4
            static let statusGap: CGFloat = 10
            static let statusIcon: CGFloat = 18
            static let ring: CGFloat = 22
            static let ringLine: CGFloat = 2.5
            static let moreIcon: CGFloat = 20
            static let moreTouch: CGFloat = 44
            static let ringMinArc: CGFloat = 0.02
            static let gaugeNative: CGFloat = 52
            static let ringIcon: CGFloat = 11
        }
        enum SeriesHeader {
            static let coverMargin: CGFloat = 36
            static let coverRadius: CGFloat = 12
            static let coverTop: CGFloat = 8
            static let titleTop: CGFloat = 16
            static let buttonsTop: CGFloat = 16
            static let buttonHeight: CGFloat = 50
            static let buttonGap: CGFloat = 12
            static let buttonIcon: CGFloat = 18
            static let buttonIconGap: CGFloat = 8
            static let descTop: CGFloat = 16
            static let descLines: CGFloat = 3
            static let moreFade: CGFloat = 40
            static let infoTop: CGFloat = 10
            static let separatorTop: CGFloat = 20
            static let sectionTop: CGFloat = 20
            static let sectionBottom: CGFloat = 4
            enum Shadow {
                static let opacity: CGFloat = 0.18
                static let radius: CGFloat = 30
                static let offsetY: CGFloat = 12
                static let androidElevation: CGFloat = 16
            }
        }
        enum Capsule {
            static let thumb: CGFloat = 36
            static let thumbRadius: CGFloat = 8
            static let paddingH: CGFloat = 8
            static let textGap: CGFloat = 10
            static let playIcon: CGFloat = 22
            static let forwardIcon: CGFloat = 30
            static let iconTouch: CGFloat = 44
            static let emptyIcon: CGFloat = 20
            static let thumbInset: CGFloat = 4
        }
        enum About {
            static let logoWidth: CGFloat = 150
            static let logoTop: CGFloat = 36
            static let nameTop: CGFloat = 16
            static let rowsTop: CGFloat = 40
            static let rowMinHeight: CGFloat = 56
            static let footerTop: CGFloat = 40
            static let footerGap: CGFloat = 4
        }
        enum Player {
            static let grabberHeight: CGFloat = 5
            static let grabberTop: CGFloat = 8
            static let coverSideMargin: CGFloat = 20
            static let coverMinPad: CGFloat = 24
            static let coverRadius: CGFloat = 14
            static let coverMinRatio: CGFloat = 0.6
            static let bottomPad: CGFloat = 32
            static let titleToBar: CGFloat = 28
            static let barToControls: CGFloat = 36
            static let controlsSideMargin: CGFloat = 22
            static let timeTop: CGFloat = 8
            static let seekIcon: CGFloat = 40
            static let playIcon: CGFloat = 52
            static let moonIcon: CGFloat = 24
            static let moreButton: CGFloat = 36
            static let moreIcon: CGFloat = 20
            static let courseGap: CGFloat = 2
            static let tabletPortraitMaxWidth: CGFloat = 640
            enum LandscapeTablet {
                static let cover: CGFloat = 500
                static let right: CGFloat = 420
                static let gap: CGFloat = 64
                static let side: CGFloat = 56
            }
            enum LandscapePhone {
                static let cover: CGFloat = 330
                static let right: CGFloat = 340
                static let gap: CGFloat = 44
                static let side: CGFloat = 60
                static let coverHeightInset: CGFloat = 48
                static let tightGap: CGFloat = 18
            }
            enum CoverShadow {
                static let opacity: CGFloat = 0.18
                static let radius: CGFloat = 30
                static let offsetY: CGFloat = 12
                static let androidElevation: CGFloat = 16
            }
            static let courseMinHeight: CGFloat = 26
        }
        enum Sheet {
            static let radius: CGFloat = 14
            static let contentTop: CGFloat = 8
            static let categoryTop: CGFloat = 4
            static let bodyTop: CGFloat = 16
        }
        enum EmptyState {
            static let paddingH: CGFloat = 40
        }
        enum Splash {
            static let logoWidth: CGFloat = 120
        }
        enum Init {
            static let spinnerGap: CGFloat = 16
            static let lineGap: CGFloat = 8
        }
        enum Vision {
            static let pageMargin: CGFloat = 24
            static let sectionGap: CGFloat = 32
            static let cardGap: CGFloat = 20
            static let largeCardWidth: CGFloat = 320
            static let cardWidth: CGFloat = 240
            static let categoryMinWidth: CGFloat = 240
            static let categoryAspectRatio: CGFloat = 1.7777777778
            static let categoryIconSize: CGFloat = 64
            static let playerCoverWidth: CGFloat = 320
            static let miniPlayerWidth: CGFloat = 600
            static let hitSize: CGFloat = 60
            static let hitGap: CGFloat = 8
            static let playerInfoHeight: CGFloat = 134
            static let actionsWidth: CGFloat = 320
            static let playerWindowGap: CGFloat = 16
        }
        enum MacMiniPlayer {
            static let width: CGFloat = 700
            static let artworkWidth: CGFloat = 60
            static let artworkHeight: CGFloat = 34
            static let spacing: CGFloat = 12
            static let padding: CGFloat = 12
            static let verticalPadding: CGFloat = 4
            static let infoRadius: CGFloat = 6
            static let controlSpacing: CGFloat = 12
            static let controlSize: CGFloat = 28
            static let rateWidth: CGFloat = 64
            static let controlIconSize: CGFloat = 20
            static let infoMaxWidth: CGFloat = 680
            static let infoHeight: CGFloat = 52
            static let idleProgressScale: CGFloat = 0.35
            static let progressLift: CGFloat = 12
            static let idleTrackOffset: CGFloat = 4
            static let metadataOffset: CGFloat = 4
        }
        enum CompactPlayer {
            static let width: CGFloat = 1080
            static let artworkWidth: CGFloat = 96
            static let artworkHeight: CGFloat = 54
            static let spacing: CGFloat = 12
            static let padding: CGFloat = 12
            static let infoRadius: CGFloat = 6
            static let minWidth: CGFloat = 480
            static let controlSpacing: CGFloat = 24
            static let controlSize: CGFloat = 48
            static let controlIconSize: CGFloat = 28
            static let infoMaxWidth: CGFloat = 680
            static let infoHeight: CGFloat = 80
            static let idleProgressScale: CGFloat = 0.12
            static let progressLift: CGFloat = 16
            static let activeProgressScale: CGFloat = 0.35
            static let timeProgressGap: CGFloat = -8
            static let roundTrackHeight: CGFloat = 8
            static let roundTrackIdleScale: CGFloat = 0.375
            static let nativeSliderOpacity: CGFloat = 0.01
            static let idleTrackOffset: CGFloat = 14
            static let rateWidth: CGFloat = 80
            static let leadingInset: CGFloat = 12
            static let verticalPadding: CGFloat = 4
            static let metadataOffset: CGFloat = 6
        }
        enum WatchPlayer {
            static let spacing: CGFloat = 8
            static let playSize: CGFloat = 72
            static let skipSize: CGFloat = 44
            static let actionHeight: CGFloat = 36
        }
        enum AudioWaveform {
            static let width: CGFloat = 16
            static let height: CGFloat = 14
            static let barWidth: CGFloat = 2.5
            static let spacing: CGFloat = 2
            static let spectrumGain: CGFloat = 5
            static let spectrumExponent: CGFloat = 0.5
        }
    }
    enum Motion {
        static let pressedOpacity: CGFloat = 0.7
        static let fadeMs: CGFloat = 150
        enum SharedAxis {
            static let distance: CGFloat = 30
            static let durationMs: CGFloat = 300
            static let fadeOutMs: CGFloat = 90
        }
    }
    enum Widget {
        static let playProgressDiameter: CGFloat = 32
        static let latestPlayProgressDiameter: CGFloat = 24
        static let gaugeNative: CGFloat = 52
        static let visionHitSize: CGFloat = 60
        static let visionHitGap: CGFloat = 8
    }
}
