package example;

import example.shout.Shout;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import org.apache.commons.lang3.StringUtils;

public final class Greeting {

    private Greeting() {}

    public static String of(String name) {
        return "Hello, " + StringUtils.capitalize(name) + "!";
    }

    public static String loud(String name) {
        return Shout.of(of(name));
    }

    /** The Node.js checksums file that the build fetched from an Ivy repository. */
    public static String nodeChecksums() {
        try (InputStream in = Greeting.class.getResourceAsStream("/node-checksums.txt")) {
            if (in == null) {
                throw new IllegalStateException("node-checksums.txt is missing");
            }
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
