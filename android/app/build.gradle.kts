plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// 版本号按发布日期：versionName 年.月.日，versionCode = 日期去点 + 两位当天序号（从 01 开始）。
// 两端共用仓库根目录的 Version.xcconfig，这里不写数字。
val versionFile = rootDir.parentFile.resolve("Version.xcconfig")
val versionProps = versionFile.readLines()
    .map { it.substringBefore("//").trim() }
    .filter { "=" in it }
    .associate { it.substringBefore("=").trim() to it.substringAfter("=").trim() }
val appVersionName =
    versionProps["MARKETING_VERSION"] ?: error("Version.xcconfig 缺 MARKETING_VERSION")
val appVersionCode = versionProps["CURRENT_PROJECT_VERSION"]?.toIntOrNull()
    ?: error("Version.xcconfig 缺 CURRENT_PROJECT_VERSION")
// 构建号必须是“日期去点 + 两位序号”，对不上就不让打包，免得两个数字改了一个忘了另一个
check(
    Regex("""\d{4}\.\d{2}\.\d{2}""").matches(appVersionName) && appVersionCode.toString().length == 10 &&
            appVersionCode.toString().startsWith(appVersionName.replace(".", ""))
) {
    "Version.xcconfig 里的版本号 $appVersionName 和构建号 $appVersionCode 对不上"
}

// 正式签名：原生版自己的一把（以后不再换）。密钥放在项目外，路径和口令写在用户目录的
// ~/.gradle/gradle.properties（ZBFW_UPLOAD_STORE_FILE 等四项），不写进项目里的任何文件。
fun signingProp(name: String): String? = providers.gradleProperty(name).orNull

android {
    namespace = "com.zhibeifw.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.zhibeifw.app"
        minSdk = 24
        targetSdk = 36
        versionCode = appVersionCode
        versionName = appVersionName
        // 渠道：site＝官网 APK（有“检查更新”）；以后 Google Play 版设为 store
        buildConfigField("String", "CHANNEL", "\"site\"")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        val storePath = signingProp("ZBFW_UPLOAD_STORE_FILE")
        if (storePath != null) {
            create("release") {
                storeFile = file(storePath)
                storePassword = signingProp("ZBFW_UPLOAD_STORE_PASSWORD")
                keyAlias = signingProp("ZBFW_UPLOAD_KEY_ALIAS")
                keyPassword = signingProp("ZBFW_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            // 开发包和 v1.0 / 正式包并存（签名不同，不能覆盖安装）；正式包仍是 com.zhibeifw.app
            applicationIdSuffix = ".dev"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfigs.findByName("release")?.let { signingConfig = it }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    implementation(libs.androidx.core)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.navigation.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.animation)
    implementation(libs.compose.material3)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.session)
    implementation(libs.datastore.preferences)
    implementation(libs.browser)
    implementation(libs.splashscreen)
    implementation(libs.coroutines.android)
    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
}
