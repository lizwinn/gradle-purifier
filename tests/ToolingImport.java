// SPDX-License-Identifier: MIT

import java.io.File;
import org.gradle.tooling.GradleConnector;
import org.gradle.tooling.ProjectConnection;
import org.gradle.tooling.model.eclipse.EclipseExternalDependency;
import org.gradle.tooling.model.eclipse.EclipseProject;

/**
 * Imports a build through the Gradle tooling API, as Buildship and jdtls do: it fetches the
 * EclipseProject model, which resolves the classpath with sources. It prints one line per
 * library of the root project, the file name of the library and, after a tab, the file name of
 * its sources or nothing.
 *
 * <p>Usage: {@code java ToolingImport <build root> <Gradle home> <Gradle user home>}.
 */
public final class ToolingImport {

  public static void main(String[] args) {
    try (ProjectConnection connection =
        GradleConnector.newConnector()
            .forProjectDirectory(new File(args[0]))
            .useInstallation(new File(args[1]))
            .useGradleUserHomeDir(new File(args[2]))
            .connect()) {
      EclipseProject project = connection.model(EclipseProject.class).get();
      for (EclipseExternalDependency dependency : project.getClasspath()) {
        File source = dependency.getSource();
        System.out.println(
            dependency.getFile().getName() + "\t" + (source == null ? "" : source.getName()));
      }
    }
  }
}
