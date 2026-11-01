plugins {
    id("kotlin-conventions")
    application
}

dependencies {
    implementation(project(":core"))
    implementation(project(":shared"))
}

application {
    mainClass = "example.app.MainKt"
}
