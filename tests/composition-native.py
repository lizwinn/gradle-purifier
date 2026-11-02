#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native inputs and projected runtime closures for ordinary downstream tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(['nix', 'eval', '--impure', '--raw', '--expr',
                                  'builtins.currentSystem'], text=True).strip()
snapshot = json.loads(subprocess.check_output(['nix', 'flake', 'metadata', '--json',
    '--no-write-lock-file', 'path:' + str(root)], text=True))['path']
with tempfile.TemporaryDirectory(prefix='gradle-native-composition-') as temporary:
    temporary = Path(temporary)
    subprocess.run(['nix-store', '--add-root', str(temporary / 'source'), '--realise', snapshot], check=True)
    package = subprocess.check_output(['nix', 'build', str(root) + '#default', '--print-out-paths',
        '--out-link', str(temporary / 'cli')], text=True).strip().splitlines()[-1]
    cli = Path(package) / 'bin/gradle-purifier'
    expression = '''let
      f=builtins.getFlake ("path:"+builtins.getEnv "COMPOSITION_FLAKE");
      p=f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
    in p.runCommand "composition-downstream-tools" {} ''
      mkdir -p "$out/bin"
      ln -s ${p.maven}/bin/mvn "$out/bin/mvn"
      ln -s ${p.jdk21_headless.home} "$out/jdk"
    '' '''
    tools = Path(subprocess.check_output(['nix', 'build', '--impure', '--print-out-paths',
        '--out-link', str(temporary / 'tools'), '--expr', expression], text=True,
        env=dict(os.environ, COMPOSITION_FLAKE=str(root))).strip())
    for transitive in (False, True):
        project = temporary / ('transitive' if transitive else 'direct')
        shutil.copytree(root / 'tests/fixtures/java-library', project)
        (project / 'gradle-purifier.lock.json').unlink()
        if transitive:
            build = project / 'build.gradle'
            build.write_text(build.read_text().replace('org.apache.commons:commons-lang3:3.17.+',
                                                       'org.apache.commons:commons-text:1.13.0'))
            source = project / 'src/main/java/example/Greeting.java'
            source.write_text(source.read_text().replace('org.apache.commons.lang3.StringUtils',
                'org.apache.commons.text.WordUtils').replace('StringUtils.capitalize', 'WordUtils.capitalizeFully'))
        reference = 'path:' + snapshot + '#checks.' + system + '.composition.producer'
        env = dict(os.environ, GRADLE_USER_HOME=str(temporary / 'native-home'))
        def run(*arguments, cwd=project, environment=env):
            subprocess.run([str(value) for value in arguments], cwd=cwd, env=environment, check=True)
        run(cli, 'lock', '--input', reference)
        data = json.loads((project / 'gradle-purifier.lock.json').read_text())
        assert len(data['projectInputs']) == 1
        assert not any('/org/apache/commons/commons-lang3/' in entry.get('path', entry.get('url', ''))
                       for entry in data['artifacts'])
        run(cli, 'prefetch')
        gradle = project / '.gradle-purifier/distribution/bin/gradle'
        run(gradle, '--no-daemon', 'clean', 'check')
        shutil.rmtree(project / 'build/classes', ignore_errors=True)
        shutil.rmtree(project / 'shout/build/classes', ignore_errors=True)
        run(cli, 'publish', 'publishMavenPublicationToLocalRepository')
        assert not (project / 'build/classes').exists(), 'publishing compiled the working tree'
        assert not (project / 'shout/build/classes').exists(), 'publishing compiled the included build'
        repository = project / 'build/local-repository'
        pom = next((repository / 'example/greeting').glob('*/*.pom'))
        version = pom.parent.name
        assert '-nix-' in version
        model = ET.parse(pom)
        dependencies = model.findall('./{*}dependencies/{*}dependency')
        expected = {'shout', 'commons-text' if transitive else 'commons-lang3'}
        for dependency in dependencies:
            if dependency.findtext('{*}artifactId') in expected:
                assert '-nix-' in dependency.findtext('{*}version')
        assert next((repository / 'example/shout').glob('*/*-nix-*.jar')).is_file()
        downstream = temporary / ('downstream-transitive' if transitive else 'downstream-direct')
        source = downstream / 'src/main/java/example/Downstream.java'
        source.parent.mkdir(parents=True)
        source.write_text('''package example;
public final class Downstream { public static void main(String[] args) throws Exception {
    String value = Greeting.loud("nix");
    if (!value.equals("HELLO, NIX!")) throw new AssertionError(value);
    for (String name : new String[] {"org.apache.commons.lang3.StringUtils", "example.shout.Shout"}) {
        String origin = Class.forName(name).getProtectionDomain().getCodeSource().getLocation().toString();
        if (!origin.contains("-nix-")) throw new AssertionError(origin);
    }
    System.out.println(value);
} }
''')
        (downstream / 'pom.xml').write_text(f'''<project><modelVersion>4.0.0</modelVersion>
          <groupId>example</groupId><artifactId>downstream</artifactId><version>1</version>
          <properties><maven.compiler.release>21</maven.compiler.release></properties>
          <repositories><repository><id>projected</id><url>{repository.as_uri()}</url></repository></repositories>
          <dependencies><dependency><groupId>example</groupId><artifactId>greeting</artifactId>
            <version>{version}</version></dependency></dependencies></project>''')
        plain = dict(os.environ, JAVA_HOME=str(tools / 'jdk'),
            GRADLE_USER_HOME=str(temporary / 'ordinary-gradle-home'))
        run(tools / 'bin/mvn', '-B', '-Dmaven.repo.local=' + str(temporary / 'ordinary-m2'),
            'package', 'dependency:build-classpath', '-Dmdep.outputFile=classpath',
            cwd=downstream, environment=plain)
        run(tools / 'jdk/bin/java', '-cp', str(downstream / 'target/classes') + os.pathsep
            + (downstream / 'classpath').read_text().strip(), 'example.Downstream',
            cwd=downstream, environment=plain)
        (downstream / 'settings.gradle').write_text("rootProject.name='ordinary-downstream'\n")
        (downstream / 'build.gradle').write_text(f'''plugins {{ id 'application' }}
          repositories {{ maven {{ url='{repository.as_uri()}' }}; mavenCentral() }}
          dependencies {{ implementation 'example:greeting:{version}' }}
          application {{ mainClass='example.Downstream' }}
        ''')
        run(gradle, '--no-daemon', '--console=plain', 'run', cwd=downstream, environment=plain)
        print('GRADLE PROJECTED RUNTIME AND ORDINARY DOWNSTREAMS PASSED: '
              + ('transitive' if transitive else 'direct'))
