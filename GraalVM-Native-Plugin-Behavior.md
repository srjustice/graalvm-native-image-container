# What the GraalVM Native Build Tools Gradle plugin changes

## Executive summary

The `org.graalvm.buildtools.native` plugin does much more than select a different container base image. Applying it changes the Gradle and Spring Boot build configuration so that the application can be processed ahead of time and compiled into native machine code.

At the same time, applying the plugin does **not** globally replace every Java build with a native executable. JVM-oriented tasks such as `test` and `bootJar` still exist. The important Spring Boot behavior is that `bootBuildImage` switches to the native-image path when the GraalVM plugin is applied.

For a project that must produce both of these deliverables:

- An executable Spring Boot JAR running on a JRE
- A GraalVM native executable running without a JRE

conditionally applying the plugin provides a clear switch between the two build modes.

## Declaring the plugin is different from applying it

The example declares the plugin and its version without applying it immediately:

```kotlin
plugins {
    id("org.graalvm.buildtools.native") version "1.1.1" apply false
}
```

The `apply false` declaration makes the plugin available to the build, but it does not activate its tasks or Spring Boot integration.

The build then uses a custom Gradle project property to decide whether to apply it:

```kotlin
val nativeImageRequested = providers.gradleProperty("nativeImage").isPresent

if (nativeImageRequested) {
    apply(plugin = "org.graalvm.buildtools.native")
}
```

`nativeImage` is not a special Gradle or GraalVM property. It is a switch defined by this project. Passing `-PnativeImage` makes `nativeImageRequested` true, which causes the build script to apply the GraalVM plugin.

## What happens without the plugin

The normal build command is:

```bash
./gradlew --no-daemon clean test bootBuildImage
```

Because the GraalVM plugin is not applied:

1. Gradle compiles the Kotlin and Java code to JVM bytecode.
2. Spring Boot creates an executable application JAR.
3. `bootBuildImage` sends that JAR through the ordinary Paketo Java buildpack path.
4. Paketo contributes a Java 25 JRE to the launch layers.
5. The final container starts a Java process that launches the application JAR.

The resulting runtime can be summarized as:

```text
Ubuntu Noble Tiny run image
    + Java 25 JRE
    + application JAR and dependencies
    + Paketo launcher and configuration
```

This is a conventional JVM application image. It retains normal JVM behavior such as dynamic class loading, runtime reflection, JIT compilation, and JVM diagnostics.

## What happens when the plugin is applied

The native build command is:

```bash
./gradlew --no-daemon clean test bootBuildImage -PnativeImage
```

The project property causes `org.graalvm.buildtools.native` to be applied. The plugin itself adds GraalVM tasks, including:

- `nativeCompile`, which creates a host-native application executable
- `nativeRun`, which runs that executable
- `nativeTestCompile`, which creates a host-native test executable
- `nativeTest`, which executes tests as native code

Spring Boot also reacts to the presence of the GraalVM plugin. It automatically applies its AOT support and configures the native tasks and image build around the generated AOT assets.

Spring AOT analyzes the application at build time and generates a fixed representation of parts of the application that the JVM would normally discover dynamically. Its output includes or contributes to:

- Direct bean-instantiation and application-context initialization code
- Reflection hints
- Classpath resource hints
- Dynamic-proxy hints
- Serialization hints
- GraalVM reachability metadata
- Build-time evaluation of Spring conditions

For `bootBuildImage`, Spring Boot selects the native Paketo buildpack path. Inside the builder container, BellSoft Liberica Native Image Kit analyzes the application under GraalVM's closed-world model and compiles the reachable application code into platform-specific machine code.

The builder's JDK and Native Image compiler are build-time tools. They are not copied into the finished image. The final runtime can be summarized as:

```text
Ubuntu Noble Tiny run image
    + native application executable
    + required runtime files
    + Paketo launcher and configuration
```

There is no JRE in the native image, and its launch process executes the native binary directly.

## This changes the application, not just the image

The JVM and native variants in this repository deliberately use the same pinned builder:

```text
paketobuildpacks/builder-noble-java-tiny:0.0.160
```

The builder metadata selects the same compatible Ubuntu Noble Tiny run-image family for both outputs. The builder contains the buildpacks necessary for both Java/JRE packaging and Java Native Image compilation.

The meaningful difference is therefore not merely a different Linux image:

| JVM path | Native path |
|---|---|
| Application remains JVM bytecode | Application is compiled to native machine code |
| Final image contains an executable JAR | Final image contains a platform-specific executable |
| Paketo contributes a JRE | Native Image compiler is present only during the build |
| Launch command starts `java` | Launch command starts the native executable |
| JVM performs dynamic work at runtime | Spring AOT and GraalVM move significant work to build time |

The run image supplies the operating-system filesystem and libraries around the application. It does not determine whether the application is JVM bytecode or native machine code. The plugin state and resulting buildpack path determine that.

## What if the plugin is always applied?

Always applying the plugin does **not** mean that every Gradle command automatically creates native machine code.

For example:

```bash
./gradlew test
```

still runs ordinary JVM tests, and:

```bash
./gradlew bootJar
```

still creates an executable Spring Boot JAR. When Spring AOT is active, that JAR can also contain AOT-generated assets and native reachability metadata. Applying the GraalVM plugin therefore does not eliminate JAR creation.

Native machine code is produced only when a native-producing task or pipeline is invoked, such as:

```bash
./gradlew nativeCompile
./gradlew nativeTest
./gradlew bootBuildImage
```

The important complication is `bootBuildImage`: Spring Boot treats the applied GraalVM plugin as the signal that this task should generate a native container image. If the plugin were always applied, the project's ordinary `bootBuildImage` invocation would also take the native path.

That would make this command:

```bash
./gradlew bootBuildImage
```

produce a native container rather than the intended executable-JAR-plus-JRE container. In the current build script it could even receive the `-jvm` image name while containing a native executable, because the image naming logic uses the custom project property while Spring Boot reacts to the actual plugin state.

It is possible to design separate custom tasks or buildpack invocations while keeping the plugin permanently applied. That approach requires additional configuration to ensure that one image packages the ordinary JVM artifact and the other packages the AOT/native artifact. It also makes the distinction less obvious to developers reading or invoking the build.

## Why conditional application is appropriate here

This repository has an explicit dual-artifact requirement. The same source revision must produce:

1. A JVM image containing the executable Spring Boot JAR and a JRE.
2. A native image containing a GraalVM-compiled executable and no JRE.

Conditional plugin application gives each command an unambiguous meaning:

| Command | Plugin state | Result |
|---|---|---|
| `./gradlew bootBuildImage` | Not applied | JVM container with application JAR and JRE |
| `./gradlew bootBuildImage -PnativeImage` | Applied | Native container with machine-code executable and no JRE |
| `./gradlew test` | Not applied by default | Fast JVM test suite |
| `./gradlew -PnativeImage nativeCompile` | Applied | Native executable for the developer's host OS and architecture |
| `./gradlew -PnativeImage nativeTest` | Applied | Tests compiled and executed as native code on the developer's host |

This arrangement has several advantages:

- The default build remains the existing JVM delivery path.
- Native behavior requires an explicit opt-in.
- Image names accurately describe their contents.
- The same `bootBuildImage` integration can be used for both variants.
- Developers do not need a local GraalVM installation for the Paketo native-container build.
- The team can retain the JVM image while native compatibility and production behavior are still being validated.

The recommendation is therefore to keep the plugin declared with `apply false` and apply it only when `-PnativeImage` is present for as long as the project needs both container variants.

## Build-flow summary

```text
./gradlew bootBuildImage
    -> GraalVM plugin not applied
    -> ordinary Spring Boot JAR
    -> Paketo Java/JRE buildpack path
    -> JVM container

./gradlew bootBuildImage -PnativeImage
    -> GraalVM plugin applied
    -> Spring AOT processing
    -> Paketo Java Native Image buildpack path
    -> Liberica NIK native compilation
    -> native container
```

## References

- [Spring Boot Gradle plugin: Ahead-of-Time Processing](https://docs.spring.io/spring-boot/gradle-plugin/aot.html)
- [Spring Boot Gradle plugin: Reacting to the GraalVM Native Image plugin](https://docs.spring.io/spring-boot/gradle-plugin/reacting.html)
- [Spring Boot: Developing a GraalVM native application](https://docs.spring.io/spring-boot/how-to/native-image/developing-your-first-application.html)
- [GraalVM Native Build Tools Gradle plugin](https://graalvm.github.io/native-build-tools/latest/gradle-plugin)
