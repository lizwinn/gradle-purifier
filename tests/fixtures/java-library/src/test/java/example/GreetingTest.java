package example;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class GreetingTest {

    @Test
    void capitalizesTheName() {
        assertEquals("Hello, Nix!", Greeting.of("nix"));
    }

    @Test
    void shoutsThroughTheIncludedBuild() {
        assertEquals("HELLO, NIX!", Greeting.loud("nix"));
    }

    @Test
    void shipsTheFileFromTheIvyRepository() {
        assertTrue(Greeting.nodeChecksums().contains("node-v20.11.0-linux-x64.tar.xz"));
    }
}
