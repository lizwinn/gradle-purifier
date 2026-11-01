// A Kotlin/Native build: a linuxX64 library with tests, published, and an
// executable linked from it.
plugins {
    kotlin("multiplatform") version "2.2.20"
    `maven-publish`
}

group = "example"
version = "1.0.0"

kotlin {
    linuxX64 {
        binaries.executable {
            baseName = "hello"
            entryPoint = "example.hello.main"
        }
    }

    sourceSets {
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
