package example.hello

fun greeting(name: String): String = "Hello, ${name.replaceFirstChar { it.uppercase() }}!"

fun main() {
    println(greeting("nix"))
}
