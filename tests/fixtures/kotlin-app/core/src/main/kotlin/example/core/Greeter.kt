package example.core

import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking

fun greeting(name: String): String = runBlocking {
    async { "Hello, ${name.replaceFirstChar { it.uppercase() }}!" }.await()
}
