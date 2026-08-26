allprojects {
    repositories {
        google()
        mavenCentral()
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
// camera_android_camerax compiles against androidx.camera camera-core whose
// jspecify-annotated SurfaceRequest references androidx.concurrent.futures;
// that class is not pulled in transitively under this toolchain. Surfacing it
// on every subproject (the plugin modules included) fixes the javac 17
// "Cannot attach type annotations ... CallbackToFutureAdapter not found" error.
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library")) {
            dependencies.add(
                "implementation",
                "androidx.concurrent:concurrent-futures:1.2.0",
            )
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
