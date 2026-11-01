package example.hello

import kotlin.test.Test
import kotlin.test.assertEquals

class HelloTest {

    @Test
    fun capitalizesTheName() {
        assertEquals("Hello, Nix!", greeting("nix"))
    }
}
