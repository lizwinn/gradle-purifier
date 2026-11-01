package example.shout;

import org.apache.commons.text.WordUtils;

public final class Shout {

    private Shout() {}

    public static String of(String text) {
        return WordUtils.capitalizeFully(text).toUpperCase();
    }
}
