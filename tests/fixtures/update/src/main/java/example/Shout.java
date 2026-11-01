package example;

import org.apache.commons.lang3.StringUtils;

public final class Shout {
  private Shout() {}

  public static String shout(String text) {
    return StringUtils.upperCase(text) + "!";
  }
}
