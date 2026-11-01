plugins {
    id("kotlin-conventions")
    `maven-publish`
}

group = "example"
version = "1.0.0"

dependencies {
    api(libs.kotlinx.coroutines.core)
}

java {
    withSourcesJar()
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])
        }
    }
}
