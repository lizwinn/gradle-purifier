package example.core

import kotlin.test.Test
import kotlin.test.assertEquals

class GreeterTest {

    @Test
    fun capitalizesTheName() {
        assertEquals("Hello, Nix!", greeting("nix"))
    }
}
