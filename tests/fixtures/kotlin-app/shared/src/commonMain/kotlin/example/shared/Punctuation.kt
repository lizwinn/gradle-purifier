package example.shared

fun exclaim(text: String): String = if (text.endsWith("!")) text else "$text!"
