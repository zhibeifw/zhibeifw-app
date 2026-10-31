# 智悲佛网 App


## 下载

- iPhone：App Store（上架后补链接）
- Android：官网 <https://zhibeifw.com>

## 目录

```
ios/            iOS 版（Swift、SwiftUI），Xcode 工程 ios/ZhibeiFW.xcodeproj
android/        Android 版（Kotlin、Jetpack Compose），Gradle 工程
doc/            设计令牌（design-tokens.json）和图标数据
tools/          gen_design.py：由设计令牌生成两端的常量文件；pre-commit：提交前用 gitleaks 检查；format/：Swift 格式化配置
Version.xcconfig  两端共用的版本号
```

两端界面里的颜色、字号、间距、尺寸都来自 `doc/design-tokens.json`。改了它以后运行：

```sh
python3 tools/gen_design.py
```

会重新生成 `ios/ZhibeiFW/Design/Generated/` 和 `android/app/src/main/java/com/zhibeifw/app/design/generated/` 里的文件。生成的文件不要手改。

## 编译

**iOS**：Xcode 26 或以上，系统要求 iOS 18 及以上。打开 `ios/ZhibeiFW.xcodeproj`，在 Signing 里换成你自己的开发者团队即可运行。

**Android**：Android Studio 或命令行，系统要求 Android 7.0 及以上。

```sh
cd android
./gradlew assembleDebug        # 调试包
./gradlew testDebugUnitTest    # 单元测试
```

正式包需要签名密钥，从 `~/.gradle/gradle.properties` 读取 `ZBFW_UPLOAD_STORE_FILE`、`ZBFW_UPLOAD_STORE_PASSWORD`、`ZBFW_UPLOAD_KEY_ALIAS`、`ZBFW_UPLOAD_KEY_PASSWORD`，仓库里没有密钥。

**版本号**：两端都读根目录的 `Version.xcconfig`。`MARKETING_VERSION` 是发布日期（如 `2026.10.31`），`CURRENT_PROJECT_VERSION` 是日期加两位当天序号（如 `2026103107`）。

## 依赖

不用任何第三方库。iOS 只用苹果的系统框架；Android 只用 Android SDK、Google 官方的 AndroidX / Jetpack 库和 Kotlin 官方的 kotlinx.coroutines。

## 许可

代码以 [Apache License 2.0](LICENSE) 发布，第三方素材见 [NOTICE](NOTICE)。

**“智悲佛网”的名称和 Logo 不在开源许可范围内**，未经许可不得使用。

课程音频和封面不在这个仓库里，也不随代码一起授权。

## 联系

dev@zhibeifw.com
