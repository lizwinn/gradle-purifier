// SPDX-License-Identifier: MIT

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.Writer;
import java.net.Authenticator;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.PasswordAuthentication;
import java.net.ProxySelector;
import java.net.URI;
import java.net.URLDecoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.util.Base64;
import java.util.List;
import java.util.Set;
import java.util.concurrent.Executors;

/**
 * The download recorder of a gradle-purifier lock run.
 *
 * <p>The init script points every remote repository of the build at this server: the URL
 * https://host/path becomes http://127.0.0.1:port/https/host/path. The server fetches the
 * remote URL and passes the response on. For every request the remote answers with 200, it
 * appends a line to the records file: the path of the file in the tree of locked downloads, the
 * remote URL, and the SRI SHA-256 hash of the body, separated by tabs. For a file whose remote
 * contents change over time (see {@link #isMutable}), the line holds "inline" and the contents
 * in Base64 instead of the URL and the hash.
 *
 * <p>Usage: {@code java Recorder <records file> <port file>}. The server listens on an ephemeral
 * port of the loopback address and writes the port to the port file once it is ready. It runs
 * until it is killed.
 *
 * <p>The server forwards the Authorization header, so a lock run can read a repository that
 * needs credentials. It takes its proxy from the https_proxy or HTTPS_PROXY environment
 * variable when one is set.
 */
public final class Recorder {

  private static final Set<String> FORWARDED_REQUEST_HEADERS =
      Set.of("accept", "authorization", "user-agent");

  private static final List<String> FORWARDED_RESPONSE_HEADERS =
      List.of("Content-Type", "Last-Modified", "ETag", "X-Checksum-Sha1", "X-Checksum-Sha256");

  private static final List<String> CHECKSUM_SUFFIXES =
      List.of(".sha1", ".sha256", ".sha512", ".md5");

  private final HttpClient client;
  private final Writer records;

  private Recorder(HttpClient client, Writer records) {
    this.client = client;
    this.records = records;
  }

  public static void main(String[] args) throws IOException {
    if (args.length != 2) {
      System.err.println("usage: java Recorder <records file> <port file>");
      System.exit(2);
    }
    Path recordsFile = Path.of(args[0]);
    Path portFile = Path.of(args[1]);

    HttpClient.Builder builder =
        HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NORMAL)
            .connectTimeout(Duration.ofSeconds(30));
    URI proxy = proxyFromEnvironment();
    if (proxy != null) {
      builder.proxy(
          ProxySelector.of(
              new InetSocketAddress(proxy.getHost(), proxy.getPort() == -1 ? 80 : proxy.getPort())));
      String userInfo = proxy.getRawUserInfo();
      if (userInfo != null) {
        // The credentials of a proxy URL such as http://user:password@host:port. Java sends
        // them through an HTTPS tunnel only when the command clears
        // jdk.http.auth.tunneling.disabledSchemes, which it does.
        int colon = userInfo.indexOf(':');
        String user = decode(colon == -1 ? userInfo : userInfo.substring(0, colon));
        char[] password = decode(colon == -1 ? "" : userInfo.substring(colon + 1)).toCharArray();
        builder.authenticator(
            new Authenticator() {
              @Override
              protected PasswordAuthentication getPasswordAuthentication() {
                return getRequestorType() == RequestorType.PROXY
                    ? new PasswordAuthentication(user, password)
                    : null;
              }
            });
      }
    }

    Writer records =
        Files.newBufferedWriter(
            recordsFile,
            StandardCharsets.UTF_8,
            StandardOpenOption.CREATE,
            StandardOpenOption.APPEND);
    Recorder recorder = new Recorder(builder.build(), records);

    HttpServer server =
        HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.setExecutor(Executors.newFixedThreadPool(32));
    server.createContext("/", recorder::handle);
    server.start();

    Path tmp = Files.createTempFile(portFile.toAbsolutePath().getParent(), "port", ".tmp");
    Files.writeString(tmp, Integer.toString(server.getAddress().getPort()));
    Files.move(tmp, portFile, StandardCopyOption.ATOMIC_MOVE);
  }

  private static String decode(String text) {
    return URLDecoder.decode(text, StandardCharsets.UTF_8);
  }

  private static URI proxyFromEnvironment() {
    for (String name : List.of("https_proxy", "HTTPS_PROXY")) {
      String value = System.getenv(name);
      if (value != null && !value.isEmpty()) {
        return URI.create(value.contains("://") ? value : "http://" + value);
      }
    }
    return null;
  }

  /**
   * The remote URL of a request path such as /https/repo.maven.apache.org/maven2/x, or null when
   * the path does not name one.
   */
  static URI remoteOf(String rawPath) {
    String[] parts = rawPath.split("/", 4);
    // parts[0] is the empty text before the leading slash.
    if (parts.length < 4 || !(parts[1].equals("http") || parts[1].equals("https"))) {
      return null;
    }
    return URI.create(parts[1] + "://" + parts[2] + "/" + parts[3]);
  }

  /** The path of a remote file in the tree of locked downloads. */
  static String treePathOf(URI remote) {
    String authority = remote.getPort() == -1 ? remote.getHost() : remote.getHost() + ":" + remote.getPort();
    return remote.getScheme() + "/" + authority + remote.getPath();
  }

  private void handle(HttpExchange exchange) throws IOException {
    try {
      forward(exchange);
    } finally {
      exchange.close();
    }
  }

  private void forward(HttpExchange exchange) throws IOException {
    String method = exchange.getRequestMethod();
    URI remote = remoteOf(exchange.getRequestURI().getRawPath());
    if (remote == null || !(method.equals("GET") || method.equals("HEAD"))) {
      exchange.sendResponseHeaders(remote == null ? 404 : 405, -1);
      return;
    }

    // A HEAD goes to the remote as a GET. Gradle sends HEAD to compare a
    // remote file's checksum headers with a file it already holds from
    // another repository, and reuses that file when they match. The lock
    // must hold the file at this repository's path as well, or the
    // sandboxed build, which reads only this path, does not find it.
    HttpRequest.Builder request =
        HttpRequest.newBuilder(remote).timeout(Duration.ofMinutes(10)).GET();
    exchange
        .getRequestHeaders()
        .forEach(
            (name, values) -> {
              if (FORWARDED_REQUEST_HEADERS.contains(name.toLowerCase())) {
                values.forEach(v -> request.header(name, v));
              }
            });

    HttpResponse<InputStream> response;
    try {
      response = client.send(request.build(), HttpResponse.BodyHandlers.ofInputStream());
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      exchange.sendResponseHeaders(502, -1);
      return;
    } catch (IOException e) {
      System.err.println("gradle-purifier recorder: " + remote + ": " + e);
      exchange.sendResponseHeaders(502, -1);
      return;
    }

    for (String name : FORWARDED_RESPONSE_HEADERS) {
      response.headers().firstValue(name).ifPresent(v -> exchange.getResponseHeaders().add(name, v));
    }
    int status = response.statusCode();
    long length = response.headers().firstValueAsLong("Content-Length").orElse(-1);

    MessageDigest sha256 = sha256();
    ByteArrayOutputStream contents = isMutable(remote) ? new ByteArrayOutputStream() : null;
    try (InputStream body = response.body()) {
      if (method.equals("HEAD")) {
        long read = drain(body, sha256, contents);
        exchange.getResponseHeaders().add("Content-Length", Long.toString(length >= 0 ? length : read));
        exchange.sendResponseHeaders(status, -1);
      } else {
        // A length of 0 makes the server send the body in chunks, and -1 sends no body.
        exchange.sendResponseHeaders(status, length > 0 ? length : (length == 0 ? -1 : 0));
        try (OutputStream out = exchange.getResponseBody()) {
          drain(body, sha256, contents == null ? out : new TeeOutputStream(out, contents));
        }
      }
    }
    if (status == 200) {
      record(remote, sha256, contents);
      // Gradle may also compare a checksum file with a file it already
      // holds, and then fetches only the checksum file; the file it
      // describes is recorded too.
      URI described = describedBy(remote);
      if (described != null) {
        recordFetched(described);
      }
    }
  }

  /** The file a checksum file such as x.jar.sha1 describes, or null for any other file. */
  static URI describedBy(URI remote) {
    String path = remote.getRawPath();
    for (String suffix : CHECKSUM_SUFFIXES) {
      if (path.endsWith(suffix)) {
        return remote.resolve(path.substring(path.lastIndexOf('/') + 1, path.length() - suffix.length()));
      }
    }
    return null;
  }

  /** Fetches `remote` and records it when the remote answers with 200. */
  private void recordFetched(URI remote) throws IOException {
    HttpRequest request = HttpRequest.newBuilder(remote).timeout(Duration.ofMinutes(10)).GET().build();
    try {
      HttpResponse<InputStream> response = client.send(request, HttpResponse.BodyHandlers.ofInputStream());
      MessageDigest sha256 = sha256();
      ByteArrayOutputStream contents = isMutable(remote) ? new ByteArrayOutputStream() : null;
      try (InputStream body = response.body()) {
        drain(body, sha256, contents);
      }
      if (response.statusCode() == 200) {
        record(remote, sha256, contents);
      }
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    } catch (IOException e) {
      System.err.println("gradle-purifier recorder: " + remote + ": " + e);
    }
  }

  /** Reads `body` to its end into `sha256`, and into `out` when it is not null. */
  private static long drain(InputStream body, MessageDigest sha256, OutputStream out)
      throws IOException {
    byte[] buffer = new byte[64 * 1024];
    long total = 0;
    int n;
    while ((n = body.read(buffer)) != -1) {
      sha256.update(buffer, 0, n);
      if (out != null) {
        out.write(buffer, 0, n);
      }
      total += n;
    }
    return total;
  }

  /**
   * Whether the remote file changes when a new version is published: Maven's version listings
   * (maven-metadata.xml and its checksum files), which Gradle reads for dynamic versions and
   * snapshots. The lock holds such a file's contents rather than a hash of its URL.
   */
  static boolean isMutable(URI remote) {
    String path = remote.getPath();
    return path.substring(path.lastIndexOf('/') + 1).startsWith("maven-metadata");
  }

  /**
   * Records a fetched file: by its hash, or by its contents when `contents` holds them. A
   * contents record has "inline" in place of the URL and the contents in Base64 in place of the
   * hash.
   */
  private void record(URI remote, MessageDigest sha256, ByteArrayOutputStream contents)
      throws IOException {
    String path = treePathOf(remote);
    if (path.endsWith("/")) {
      return;
    }
    if (contents != null) {
      record(path, "inline", Base64.getEncoder().encodeToString(contents.toByteArray()));
    } else {
      record(path, remote.toString(), "sha256-" + Base64.getEncoder().encodeToString(sha256.digest()));
    }
  }

  /** Writes to two streams; closing it closes the first only. */
  private static final class TeeOutputStream extends OutputStream {
    private final OutputStream first;
    private final OutputStream second;

    TeeOutputStream(OutputStream first, OutputStream second) {
      this.first = first;
      this.second = second;
    }

    @Override
    public void write(int b) throws IOException {
      first.write(b);
      second.write(b);
    }

    @Override
    public void write(byte[] b, int off, int len) throws IOException {
      first.write(b, off, len);
      second.write(b, off, len);
    }

    @Override
    public void flush() throws IOException {
      first.flush();
    }

    @Override
    public void close() throws IOException {
      first.close();
    }
  }

  private synchronized void record(String path, String url, String hash) throws IOException {
    records.write(path + "\t" + url + "\t" + hash + "\n");
    records.flush();
  }

  private static MessageDigest sha256() {
    try {
      return MessageDigest.getInstance("SHA-256");
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }
}
