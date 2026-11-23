#!/bin/sh
set -eu
LC_ALL=C
TZ=UTC
export LC_ALL TZ
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERSION=0.3.0
ERROR_PRONE_VERSION=2.51.0
ERROR_PRONE_SHA256=9a6aee2aa413500ac9314bfb22a30b6a4992aeb1156ddfd5f8d5c3dc280f1af1
NECO_QUOTIENT_VERSION=0.2.0
NECO_QUOTIENT_SHA256=738937c9d56f731fd2dadbebcc12852de068b0e9060ee76ab465624874c3362d
NECO_QUOTIENT_APPLICATION_VERSION=0.1.0
NECO_QUOTIENT_APPLICATION_SHA256=8ea2c5375e716b4c538a18dff6e3327cd5f21b4d3c292950d95fe5c6820380d9
NECO_QUOTIENT_RETENTION_VERSION=0.1.0
NECO_QUOTIENT_RETENTION_SHA256=548f4ae83d78dc8539c5f996a17a70d1a1a380b6164d0935e483507e1d0876fb
NECO_QUOTIENT_ENCODING_VERSION=0.1.0
NECO_QUOTIENT_ENCODING_SHA256=14c72eb8b371c11ced49cfde1cc948bd6e15a0de31b2269df148b104656b4469
OUT=${2:-"$ROOT/adapter/build/maven"}
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac
case "${1:-build}" in
  build)
    [ ! -e "$OUT" ] || { echo "output already exists: $OUT" >&2; exit 1; }
    javac -version 2>&1 | grep -E '^javac 21([. ]|$)' >/dev/null || {
      echo 'JDK 21 is required' >&2; exit 1;
    }
    mkdir -p "$OUT"
    WORK=$(mktemp -d "$OUT/work.XXXXXX")
    trap 'rm -rf "$WORK"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ERROR_PRONE_JAR="$WORK/error_prone_core-$ERROR_PRONE_VERSION-with-dependencies.jar"
    curl --fail --location --silent --show-error \
      --output "$ERROR_PRONE_JAR" \
      "https://repo1.maven.org/maven2/com/google/errorprone/error_prone_core/$ERROR_PRONE_VERSION/error_prone_core-$ERROR_PRONE_VERSION-with-dependencies.jar"
    printf '%s  %s\n' "$ERROR_PRONE_SHA256" "$ERROR_PRONE_JAR" | shasum -a 256 -c -
    NECO_QUOTIENT_JAR="$WORK/neco-quotient-certificate-$NECO_QUOTIENT_VERSION.jar"
    curl --fail --location --silent --show-error \
      --output "$NECO_QUOTIENT_JAR" \
      "https://repo1.maven.org/maven2/io/github/barineco/neco-quotient-certificate/$NECO_QUOTIENT_VERSION/neco-quotient-certificate-$NECO_QUOTIENT_VERSION.jar"
    printf '%s  %s\n' "$NECO_QUOTIENT_SHA256" "$NECO_QUOTIENT_JAR" | shasum -a 256 -c -
    NECO_QUOTIENT_APPLICATION_JAR="$WORK/neco-quotient-application-$NECO_QUOTIENT_APPLICATION_VERSION.jar"
    curl --fail --location --silent --show-error \
      --output "$NECO_QUOTIENT_APPLICATION_JAR" \
      "https://repo1.maven.org/maven2/io/github/barineco/neco-quotient-application/$NECO_QUOTIENT_APPLICATION_VERSION/neco-quotient-application-$NECO_QUOTIENT_APPLICATION_VERSION.jar"
    printf '%s  %s\n' "$NECO_QUOTIENT_APPLICATION_SHA256" "$NECO_QUOTIENT_APPLICATION_JAR" | shasum -a 256 -c -
    NECO_QUOTIENT_RETENTION_JAR="$WORK/neco-quotient-retention-$NECO_QUOTIENT_RETENTION_VERSION.jar"
    curl --fail --location --silent --show-error \
      --output "$NECO_QUOTIENT_RETENTION_JAR" \
      "https://repo1.maven.org/maven2/io/github/barineco/neco-quotient-retention/$NECO_QUOTIENT_RETENTION_VERSION/neco-quotient-retention-$NECO_QUOTIENT_RETENTION_VERSION.jar"
    printf '%s  %s\n' "$NECO_QUOTIENT_RETENTION_SHA256" "$NECO_QUOTIENT_RETENTION_JAR" | shasum -a 256 -c -
    NECO_QUOTIENT_ENCODING_JAR="$WORK/neco-quotient-encoding-$NECO_QUOTIENT_ENCODING_VERSION.jar"
    curl --fail --location --silent --show-error \
      --output "$NECO_QUOTIENT_ENCODING_JAR" \
      "https://repo1.maven.org/maven2/io/github/barineco/neco-quotient-encoding/$NECO_QUOTIENT_ENCODING_VERSION/neco-quotient-encoding-$NECO_QUOTIENT_ENCODING_VERSION.jar"
    printf '%s  %s\n' "$NECO_QUOTIENT_ENCODING_SHA256" "$NECO_QUOTIENT_ENCODING_JAR" | shasum -a 256 -c -
    for artifact in necoherence necoherence-http-adapter; do
      if [ "$artifact" = necoherence ]; then
        source=adapter
        name='Necoherence'
        description='Revision-aware state transition utilities for Java'
      else
        source=adapter/http
        name='Necoherence HTTP adapter'
        description='HTTP host adapter for Necoherence'
      fi
      dest="$OUT/io/github/barineco/$artifact/$VERSION"
      stage="$WORK/$artifact"
      mkdir -p "$dest" "$stage/classes" "$stage/docs" "$stage/sources"
      cp -R "$ROOT/$source/src/main/java/." "$stage/sources/"
      cp "$ROOT/$source/LICENSE" "$stage/sources/LICENSE"
      (cd "$stage/sources" && find . -name '*.java' | sort) >"$stage/sources.args"
      core="$OUT/io/github/barineco/necoherence/$VERSION/necoherence-$VERSION.jar"
      if [ "$artifact" = necoherence ]; then classpath="$stage/classes:$NECO_QUOTIENT_JAR:$NECO_QUOTIENT_APPLICATION_JAR:$NECO_QUOTIENT_RETENTION_JAR:$NECO_QUOTIENT_ENCODING_JAR"; else classpath="$core:$NECO_QUOTIENT_JAR:$NECO_QUOTIENT_APPLICATION_JAR:$NECO_QUOTIENT_RETENTION_JAR:$NECO_QUOTIENT_ENCODING_JAR"; fi
      (cd "$stage/sources" &&
        javac -J-Duser.language=en -encoding UTF-8 --release 21 -Xlint:all -Werror \
          -XDcompilePolicy=simple -XDshould-stop.ifError=FLOW -XDaddTypeAnnotationsToSymbol=true \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.comp=ALL-UNNAMED \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.main=ALL-UNNAMED \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.model=ALL-UNNAMED \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.processing=ALL-UNNAMED \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED \
          -J--add-exports=jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED \
          -processorpath "$ERROR_PRONE_JAR" \
          "-Xplugin:ErrorProne -XepDisableAllChecks -Xep:BanJNDI:ERROR -Xep:DoNotCall:ERROR -Xep:CatchFail:ERROR -Xep:CheckReturnValue:ERROR" \
          -cp "$classpath" -d "$stage/classes" @"$stage/sources.args" &&
        javadoc -J-Duser.language=en -encoding UTF-8 -locale en -notimestamp --release 21 \
          -classpath "$classpath" -d "$stage/docs" @"$stage/sources.args")
      cp "$ROOT/$source/LICENSE" "$stage/classes/LICENSE"
      cp "$ROOT/$source/LICENSE" "$stage/docs/LICENSE"
      for kind in classes sources docs; do
        case "$kind" in classes) suffix=;; sources) suffix=-sources;; docs) suffix=-javadoc;; esac
        (cd "$stage/$kind" && find . -type f | sort) >"$stage/$kind.args"
        (cd "$stage/$kind" && jar --create --date=2026-01-01T00:00:00Z \
          --file "$dest/$artifact-$VERSION$suffix.jar" @"$stage/$kind.args")
      done
      cat >"$dest/$artifact-$VERSION.pom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.github.barineco</groupId>
  <artifactId>$artifact</artifactId>
  <version>$VERSION</version>
  <packaging>jar</packaging>
  <name>$name</name>
  <description>$description</description>
  <url>https://github.com/barineco/necoherence</url>
  <licenses><license><name>MIT</name><url>https://opensource.org/licenses/MIT</url><distribution>repo</distribution></license></licenses>
  <developers><developer><id>barineco</id><name>barineco</name></developer></developers>
  <scm>
    <url>https://github.com/barineco/necoherence</url>
    <connection>scm:git:https://github.com/barineco/necoherence.git</connection>
    <developerConnection>scm:git:ssh://git@github.com/barineco/necoherence.git</developerConnection>
    <tag>v$VERSION</tag>
  </scm>
EOF
      if [ "$artifact" = necoherence ]; then
        cat >>"$dest/$artifact-$VERSION.pom" <<EOF
  <dependencies><dependency><groupId>io.github.barineco</groupId><artifactId>neco-quotient-certificate</artifactId><version>$NECO_QUOTIENT_VERSION</version></dependency><dependency><groupId>io.github.barineco</groupId><artifactId>neco-quotient-application</artifactId><version>$NECO_QUOTIENT_APPLICATION_VERSION</version></dependency><dependency><groupId>io.github.barineco</groupId><artifactId>neco-quotient-retention</artifactId><version>$NECO_QUOTIENT_RETENTION_VERSION</version></dependency><dependency><groupId>io.github.barineco</groupId><artifactId>neco-quotient-encoding</artifactId><version>$NECO_QUOTIENT_ENCODING_VERSION</version></dependency></dependencies>
EOF
      else
        cat >>"$dest/$artifact-$VERSION.pom" <<EOF
  <dependencies><dependency><groupId>io.github.barineco</groupId><artifactId>necoherence</artifactId><version>$VERSION</version></dependency></dependencies>
EOF
      fi
      printf '%s\n' '</project>' >>"$dest/$artifact-$VERSION.pom"
    done
    ;;
  bundle)
    : "${NECOHERENCE_GPG_KEY:?set NECOHERENCE_GPG_KEY to a signing key id}"
    for artifact in necoherence necoherence-http-adapter; do
      base="$OUT/io/github/barineco/$artifact/$VERSION/$artifact-$VERSION"
      for suffix in .jar -sources.jar -javadoc.jar .pom; do
        file="$base$suffix"
        [ -f "$file" ] || { echo "missing artifact: $file" >&2; exit 1; }
      done
    done
    for artifact in necoherence necoherence-http-adapter; do
      base="$OUT/io/github/barineco/$artifact/$VERSION/$artifact-$VERSION"
      for suffix in .jar -sources.jar -javadoc.jar .pom; do
        file="$base$suffix"
        gpg --detach-sign --armor --local-user "$NECOHERENCE_GPG_KEY" "$file"
        openssl dgst -md5 -r "$file" | awk '{print $1}' >"$file.md5"
        openssl dgst -sha1 -r "$file" | awk '{print $1}' >"$file.sha1"
      done
    done
    (cd "$OUT" && find io -type f | sort | zip -X "central-bundle-$VERSION.zip" -@)
    ;;
  *) echo 'usage: packages/java/build-maven.sh [build|bundle] [output-directory]' >&2; exit 2;;
esac
