// A Kotlin Multiplatform library with a JVM target, published with the
// Multiplatform plugin's own publications.
plugins {
    id("org.jetbrains.kotlin.multiplatform")
    `maven-publish`
}

group = "example"
version = "1.0.0"

kotlin {
    jvmToolchain(21)
    jvm()

    sourceSets {
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}

tasks.named<Test>("jvmTest") {
    useJUnitPlatform()
}

dependencies {
    "jvmTestRuntimeOnly"(platform("org.junit:junit-bom:5.11.4"))
    "jvmTestRuntimeOnly"("org.junit.platform:junit-platform-launcher")
}
