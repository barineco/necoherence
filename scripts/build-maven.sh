#!/bin/sh
set -eu
LC_ALL=C
TZ=UTC
export LC_ALL TZ
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=0.2.1
OUT=${2:-"$ROOT/java/build/maven"}
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
    for artifact in necoherence necoherence-http-adapter; do
      if [ "$artifact" = necoherence ]; then
        source=java
        name='Necoherence'
        description='Revision-aware state transition utilities for Java'
      else
        source=java-http-adapter
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
      if [ "$artifact" = necoherence ]; then classpath="$stage/classes"; else classpath="$core"; fi
      (cd "$stage/sources" &&
        javac -J-Duser.language=en -encoding UTF-8 --release 21 -cp "$classpath" -d "$stage/classes" @"$stage/sources.args" &&
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
      if [ "$artifact" = necoherence-http-adapter ]; then
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
  *) echo 'usage: scripts/build-maven.sh [build|bundle] [output-directory]' >&2; exit 2;;
esac
