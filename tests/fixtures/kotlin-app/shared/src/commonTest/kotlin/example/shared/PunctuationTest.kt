package example.shared

import kotlin.test.Test
import kotlin.test.assertEquals

class PunctuationTest {

    @Test
    fun addsOneExclamationMark() {
        assertEquals("Hello!", exclaim("Hello"))
        assertEquals("Hello!", exclaim("Hello!"))
    }
}
