allprojects {
    repositories {
        google()
        mavenCentral()
        // 固定版本的 Android USB 串口驱动；Flutter 通过自有平台通道调用。
        maven(url = "https://jitpack.io")
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    plugins.withId("com.android.library") {
        // 与应用的 SDK 36 对齐。部分测试插件仍声明 35，避免为它单独下载旧平台。
        // finalizeDsl 在 AGP 创建变体之前执行；不能在任务运行后再改编译 SDK。
        extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension> {
            finalizeDsl { dsl ->
                dsl.compileSdk = maxOf(dsl.compileSdk ?: 0, 36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
