# Spring Boot JVM and GraalVM Native Image example

This repository pairs the opinionated [JVM and GraalVM Native Image delivery strategy](./GraalVM-Native-and-JVM-Container-Strategy.md) with a minimal working Spring Boot microservice. One Gradle project produces two OCI images from the same Kotlin application:

- `hello-world:0.0.1-SNAPSHOT-jvm` contains the application and a JRE.
- `hello-world:0.0.1-SNAPSHOT-native` contains the GraalVM native executable and no JVM or JRE.

Both image paths use Spring Boot's `bootBuildImage` task and the pinned Paketo Noble Java Tiny builder. There is no Dockerfile and GraalVM does not need to be installed on the host.

## What the service does

The service exposes one endpoint:

```http
GET /hello
```

It responds with HTTP 200 and:

```json
{"message":"Hello, World!"}
```

## Prerequisites

- JDK 25 available to Gradle's [toolchain detection](https://docs.gradle.org/current/userguide/toolchains.html#sec:auto_detection).
- A running Docker-compatible daemon accessible to Spring Boot.
- `curl` for the runtime checks below.
- Optional: the [`pack` CLI](https://buildpacks.io/docs/for-platform-operators/how-to/integrate-ci/pack/) for buildpack metadata and SBOM inspection.

The checked-in Gradle Wrapper downloads the expected Gradle version, so a system Gradle installation is not required. The native compiler and its build-time JDK are supplied inside the Paketo build environment.

## Test the application

```bash
./gradlew test
```

The integration test starts the Spring application and checks the endpoint's status, media type, and exact response body.

## Build the JVM image

```bash
./gradlew --no-daemon clean test bootBuildImage
```

This invocation does not apply the GraalVM plugin. Paketo packages the executable Spring Boot JAR and contributes a Java 25 JRE to the launch layers, producing:

```text
hello-world:0.0.1-SNAPSHOT-jvm
```

## Build the native image

```bash
./gradlew --no-daemon clean test bootBuildImage -PnativeImage
```

The `nativeImage` project property conditionally applies GraalVM Native Build Tools. Spring Boot then asks Paketo to compile the application ahead of time and packages the resulting executable without a JVM or JRE, producing:

```text
hello-world:0.0.1-SNAPSHOT-native
```

The example supplies `-march=compatibility` through `BP_NATIVE_IMAGE_BUILD_ARGUMENTS`. That favors compatibility across customer CPUs over build-host-specific instruction tuning.

## Run and compare both variants

Start both images on different host ports:

```bash
docker run --rm --detach \
  --name hello-world-jvm \
  --publish 8080:8080 \
  hello-world:0.0.1-SNAPSHOT-jvm

docker run --rm --detach \
  --name hello-world-native \
  --publish 8081:8080 \
  hello-world:0.0.1-SNAPSHOT-native
```

Wait for startup and call both services:

```bash
curl --fail --silent --show-error \
  --retry 30 --retry-connrefused --retry-delay 1 \
  http://localhost:8080/hello

curl --fail --silent --show-error \
  --retry 30 --retry-connrefused --retry-delay 1 \
  http://localhost:8081/hello
```

Both calls return:

```json
{"message":"Hello, World!"}
```

Stop the containers when finished:

```bash
docker stop hello-world-jvm hello-world-native
```

## Inspect what was produced

Compare the image sizes:

```bash
docker image ls hello-world
```

Confirm that Paketo configured both variants with a non-root runtime user:

```bash
docker image inspect hello-world:0.0.1-SNAPSHOT-jvm \
  --format 'JVM user: {{.Config.User}}'

docker image inspect hello-world:0.0.1-SNAPSHOT-native \
  --format 'native user: {{.Config.User}}'
```

Inspect their layers and Cloud Native Buildpacks metadata:

```bash
docker history --no-trunc hello-world:0.0.1-SNAPSHOT-jvm
docker history --no-trunc hello-world:0.0.1-SNAPSHOT-native

pack inspect hello-world:0.0.1-SNAPSHOT-jvm
pack inspect hello-world:0.0.1-SNAPSHOT-native
```

Download the final application-image SBOMs:

```bash
pack sbom download hello-world:0.0.1-SNAPSHOT-jvm \
  --output-dir ./sbom-jvm

pack sbom download hello-world:0.0.1-SNAPSHOT-native \
  --output-dir ./sbom-native
```

The JVM SBOM records the contributed Java runtime. The native SBOM does not contain a JRE launch layer. An SBOM is a component inventory rather than a file-by-file filesystem manifest; use `docker history`, `dive`, or another OCI-layer inspector when a literal filesystem view is required.

The pinned builder is `paketobuildpacks/builder-noble-java-tiny:0.0.160`. Its builder metadata selects `paketobuildpacks/ubuntu-noble-run-tiny:0.0.104` as the runtime base. Inspect that pairing directly with:

```bash
pack builder inspect paketobuildpacks/builder-noble-java-tiny:0.0.160
```

## Interpreting performance observations

You can use startup logs, `docker stats --no-stream`, and image inspection for a quick local comparison. Those observations are useful demonstrations, not a performance qualification. Production decisions should use representative traffic, identical resource limits, multiple samples, and the latency, memory, CPU, startup, and shutdown tests described in the strategy guide.

## Platform scope

The native executable is Linux- and architecture-specific. By default, `bootBuildImage` targets the platform used by the Docker daemon, such as `linux/arm64` on Apple Silicon or `linux/amd64` on an x86-64 build host. A production multi-architecture release must build and test each architecture separately before combining them into an OCI index.
