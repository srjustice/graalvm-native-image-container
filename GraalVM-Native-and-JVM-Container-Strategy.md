# Spring Boot JVM and GraalVM Native Image Delivery Strategy

**Gradle-only packaging guidance for customer-deployed microservices**  
**Status:** Recommended direction  
**Prepared:** July 2026

## Executive recommendation

Continue publishing the existing JVM-based OCI image while introducing a second, explicitly tagged GraalVM Native Image variant. Use the Spring Boot Gradle plugin and Paketo Cloud Native Buildpacks for both paths. Use `paketobuildpacks/builder-noble-java-tiny` as the standard builder for the native image and, where compatibility testing succeeds, for the JVM image as well.

The recommended release artifacts are:

```text
registry.example.com/service-a:<version>-jvm
registry.example.com/service-a:<version>-native

registry.example.com/service-b:<version>-jvm
registry.example.com/service-b:<version>-native
```

The native variant should be treated as the eventual preferred container for environments where startup time, memory density, and rapid scale-out matter. The JVM variant should remain available during validation and afterward wherever mature JVM behavior, dynamic capabilities, debugging tooling, or peak warmed-up throughput are more important.

Paketo Noble Java Tiny is the best default native-image packaging option for this situation because it is the officially supported Spring Boot path, integrates directly with Gradle, produces a minimal distroless-like runtime image, runs as non-root, generates standard OCI metadata and SBOM information, and does not put a JRE into the native runtime image. It achieves these benefits without requiring the team to own a custom Dockerfile or direct native-binary installation process.

> **Decision:** Adopt a dual-image Gradle pipeline. Make Paketo Noble Java Tiny the standard for the native OCI image. Retain the JVM image until the native variant has passed functional, compatibility, observability, performance, and customer-environment validation.

The repository's [working Spring Boot example](./README.md) implements this recommendation with Kotlin, Gradle, and two explicit image-build commands.

## 1. Goals and decision criteria

The two Spring Boot microservices are currently delivered as executable JARs in Paketo-generated OCI images containing a JRE. The objective is to add GraalVM Native Image builds while preserving a low-risk JVM delivery path.

The solution should:

- Minimize startup time and steady-state memory use.
- Avoid including a JRE where it is not needed.
- Keep the final native container as small and narrow as practical.
- Preserve a familiar Gradle and Paketo build workflow.
- Produce supportable, inspectable, non-root OCI images.
- Support customer environments based on Docker, Podman, Kubernetes, or OpenShift.
- Allow separate `linux/amd64` and `linux/arm64` artifacts when required.
- Provide SBOM, provenance, signing, vulnerability-scanning, and reproducibility hooks.
- Preserve the option to distribute host-native RPM packages later.

## 2. The recommended artifact model

### JVM image

The JVM image remains the compatibility and operational baseline. Its final runtime image contains:

- The selected Paketo run-image filesystem.
- The Cloud Native Buildpacks launcher and image metadata.
- A JRE contributed as a launch layer.
- The Spring Boot application, normally represented as optimized application layers derived from the executable JAR.
- Any detected runtime layers such as CA-certificate support.

This path retains JVM facilities such as mature JIT optimization, conventional JVM diagnostics, broader agent compatibility, and familiar runtime tuning.

### Native image

The native image uses the same broad OCI delivery model, but the buildpack compiles the application ahead of time into a platform-specific executable. Its final runtime image contains:

- The Noble Tiny run-image filesystem.
- The Cloud Native Buildpacks launcher and metadata.
- The compiled GraalVM native executable.
- Only the buildpack-contributed launch assets needed by the application, such as certificate support when detected.

It does **not** contain a JVM or JRE. The Java toolchain, Gradle, GraalVM Native Image compiler, and Ubuntu-based build environment exist only during the build and are discarded from the final image.

### Why publish both

Native Image is not merely a different wrapper around the same runtime. Ahead-of-time compilation changes reflection, resource discovery, serialization, proxy generation, class initialization, and some diagnostic behavior. Publishing both variants provides a controlled migration path:

1. Use the JVM image as the known-good reference.
2. Exercise the native image against the same functional and load tests.
3. Compare behavior and operating cost under identical container limits.
4. Promote the native image for qualified environments.
5. Retain the JVM option for exceptional integrations or workloads.

## 3. Understanding “Noble Java Tiny”

The name describes the buildpack product and its build/run pairing; it does not mean that the native runtime contains Java or a complete Ubuntu installation.

**Noble** identifies Ubuntu 24.04 “Noble Numbat” as the build environment and compatibility family used by the builder. Compilation occurs in that controlled Linux userspace.

**Java** identifies the buildpacks packaged into the builder. Those buildpacks understand Gradle, executable JARs, Spring Boot, JVM runtimes, and GraalVM Native Image. The builder can create either a JVM application image or a native application image.

**Tiny** describes the run-image strategy. The runtime has no shell and only a reduced set of system libraries. It is comparable to a distroless runtime rather than a general-purpose Ubuntu installation.

The builder image is not the runtime image. A Cloud Native Buildpacks builder contains the build image, lifecycle, and buildpacks. During export, only the selected run-image layers and the application’s launch layers become part of the final application image.

## 4. Why Paketo Noble Java Tiny is the preferred native-image path

### Official Spring Boot and Gradle integration

Spring Boot supports GraalVM Native Image container generation through its Gradle `bootBuildImage` task and the Paketo Java Native Image buildpack. Current Spring Boot documentation identifies `paketobuildpacks/builder-noble-java-tiny` as the default builder and describes it as a small-footprint image with a reduced attack surface, no shell, and a reduced system-library set.

This matters operationally: the team remains on a supported Spring Boot path instead of maintaining custom container assembly logic around a complex ahead-of-time compiler.

### Minimal final runtime

The native final image does not include:

- A JDK.
- A JRE.
- Gradle.
- The Native Image compiler.
- A shell.
- A package manager.
- The Ubuntu build toolchain.

The dominant runtime payload is the application’s native executable. The remaining content exists to satisfy OCI, Cloud Native Buildpacks, security, certificate, and runtime-library requirements.

### Repeatable supply-chain behavior

Paketo and Cloud Native Buildpacks provide a standardized mechanism for:

- Separating build and run environments.
- Running the application as a non-root user.
- Recording the builder, run image, participating buildpacks, and processes in image metadata.
- Producing and retrieving SBOM information.
- Reusing cached layers.
- Updating compatible run-image layers independently through the CNB rebase model.

### Lower ownership cost

A hand-maintained multi-stage Dockerfile can produce a similarly small image, but it transfers responsibility for the compiler image, runtime ABI, users and permissions, certificates, timezone data, native libraries, labels, SBOM generation, signing hooks, architecture matrix, and update process to the application team.

Paketo does not make these concerns disappear, but it supplies a supported and repeatable implementation with less custom code.

## 5. Gradle-only implementation strategy

### Required Gradle capabilities

The project should use:

- The Spring Boot Gradle plugin.
- The GraalVM Native Build Tools Gradle plugin for the native build path.
- The Gradle Wrapper (`./gradlew`) in local development and CI.
- A Spring Boot, JDK, GraalVM Native Build Tools, and Paketo combination supported by the project’s chosen Spring Boot release.

No Maven configuration or Maven-specific workflow is required.

### Recommended CI structure

Use two independent CI jobs or two explicit Gradle entry points. Keep their caches and output tags distinct.

#### JVM job

The JVM job should build and test the conventional application, then invoke `bootBuildImage` without enabling the GraalVM native path:

```bash
./gradlew --no-daemon clean test bootBuildImage \
  -PimageName=registry.example.com/service:${VERSION}-jvm
```

The exact image-name property can be wired into `build.gradle.kts` or supplied with Spring Boot’s `--imageName` task option. The existing Paketo JVM pipeline can remain unchanged initially. After validation, it can also standardize on Noble Java Tiny if the service needs no shell or absent native libraries; the JRE will be contributed as an application launch layer.

#### Native job

The native job should apply the GraalVM Native Build Tools plugin and invoke the same Spring Boot image task under the native build configuration:

```bash
./gradlew --no-daemon clean test bootBuildImage \
  -PnativeImage \
  -PimageName=registry.example.com/service:${VERSION}-native
```

A useful Gradle Kotlin DSL pattern is to declare the native plugin but apply it only for the native invocation:

```kotlin
import org.springframework.boot.gradle.tasks.bundling.BootBuildImage

plugins {
    java
    id("org.springframework.boot") version "<project-version>"
    id("org.graalvm.buildtools.native") version "<compatible-version>" apply false
}

if (providers.gradleProperty("nativeImage").isPresent) {
    apply(plugin = "org.graalvm.buildtools.native")
}

tasks.named<BootBuildImage>("bootBuildImage") {
    builder.set("paketobuildpacks/builder-noble-java-tiny:<pinned-version>")
    imageName.set(
        providers.gradleProperty("imageName")
            .orElse("registry.example.com/${project.name}:${project.version}")
    )
}
```

This is an implementation pattern, not a version prescription. Pin versions and digests that match the services’ actual Spring Boot and JDK baseline. Verify the final task graph in the repository because multi-project Gradle builds may require module-specific task configuration.

### Production pinning

Do not use floating `latest` references for reproducible production releases. Pin:

- The Gradle Wrapper version.
- Spring Boot and GraalVM Native Build Tools plugin versions.
- The builder version or digest.
- The resulting run-image digest recorded during the build.
- The target OS and architecture.

Refresh these pins through a controlled dependency-update process rather than allowing an unreviewed builder change during a release.

## 6. Runtime contents and verification

There are two different inventories to inspect.

### Base run-image inventory

First identify the exact run image configured by the selected builder:

```bash
pack builder inspect \
  paketobuildpacks/builder-noble-java-tiny:<pinned-version>
```

Paketo publishes version-specific CycloneDX receipts with the Ubuntu Noble base-image releases. For the identified `ubuntu-noble-run-tiny` version, download the corresponding asset named like:

```text
ubuntu-noble-run-tiny-<version>-receipt.cyclonedx.json
```

Use the architecture-specific receipt when applicable.

### Final application-image inventory

The base receipt is not the complete final image. Participating buildpacks add launch layers based on the application. Inspect the completed artifact with:

```bash
pack inspect registry.example.com/service:<version>-native

pack sbom download registry.example.com/service:<version>-native \
  --output-dir ./sbom
```

For an image that exists only in a registry:

```bash
pack sbom download registry.example.com/service:<version>-native \
  --remote \
  --output-dir ./sbom
```

An SBOM inventories software components; it is not necessarily a literal list of every file. Use `dive`, `docker history --no-trunc`, or an equivalent OCI-layer inspection tool when a file-by-file and layer-by-layer view is required.

## 7. Performance and resource-efficiency guidance

### What the base image can and cannot improve

Once a compatible minimal runtime has been selected, further base-image reductions will not materially reduce the native process’s heap, native allocations, thread stacks, or CPU cost. Optimize the executable and workload instead of chasing a few additional base-image megabytes.

### Garbage collection and heap

GraalVM Native Image uses Serial GC by default. It is optimized for small heaps and low footprint, which is a sensible starting point for these microservices. Set realistic container memory limits and test an explicit maximum heap rather than assuming that the default is optimal.

Evaluate at least:

- Normal resident set size after warm-up.
- Peak resident set size during allocation bursts and garbage collection.
- p50, p95, and p99 request latency.
- Throughput at expected and overload concurrency.
- CPU per request.
- Startup-to-readiness time.
- Graceful shutdown time.

Do not assume native will win every throughput benchmark. A long-running HotSpot JVM can use profile-driven JIT compilation and may outperform an unprofiled native executable for CPU-intensive steady-state workloads. The native image is most predictably advantageous for startup, memory density, and scale-to-zero or burst-scaling scenarios.

### CPU target

Native executables are architecture- and instruction-set-specific.

- Use `-march=compatibility` for broadly distributed customer binaries and heterogeneous x86-64 hardware.
- Use a controlled architecture baseline when all deployment nodes are known.
- Use `-march=native` only when build and deployment CPUs have equivalent features and portability is deliberately sacrificed.

For customer distribution, reliability normally matters more than the final few percent of CPU performance.

Paketo passes additional compiler arguments through `BP_NATIVE_IMAGE_BUILD_ARGUMENTS`, but any override must be tested against the exact builder and GraalVM version.

### Optimization policy

Start with Native Image’s normal optimization level and no executable compression. Then measure before changing:

- `-Os` favors binary size and can trade away execution performance.
- UPX or other binary compression may reduce transfer size but should not be enabled without cold-start, CPU, memory, scanning, and debugging validation.
- Profile-guided optimization can improve throughput when supported by the selected GraalVM distribution, but it requires a representative workload and an additional build cycle.

## 8. Compatibility and operational requirements

Before qualifying the native image, test all behavior that depends on runtime discovery or native integration:

- Reflection and serialization.
- Dynamic proxies.
- Classpath resource loading.
- Configuration binding and conditional configuration.
- TLS, trust stores, and custom certificates.
- DNS and HTTP-client behavior.
- Database drivers and connection pools.
- Messaging clients.
- JNI or other native libraries.
- Fonts, image processing, timezone data, and locale behavior when used.
- Observability agents, tracing, metrics, crash diagnostics, and heap diagnostics.
- Startup, readiness, liveness, shutdown, and termination signals.

If a service genuinely requires a shell, startup script, or system library absent from Noble Tiny, use the broader compatible Paketo Noble run image or a deliberately customized runtime. Do not add general-purpose tools merely for interactive debugging; use ephemeral debug containers or a separate diagnostic image.

## 9. Multi-architecture delivery

A GraalVM native executable is compiled for a specific operating system and architecture. It is not a universal JAR.

When customers require both major Linux architectures:

1. Build and test separate `linux/amd64` and `linux/arm64` native images.
2. Run each build on the corresponding architecture where practical.
3. Publish the architecture-specific images under a multi-architecture OCI index.
4. Keep SBOMs, signatures, provenance, and test results associated with each platform digest.

The JVM image remains more architecture-neutral at the application layer, but its final OCI image still needs architecture-specific JRE and base-image layers.

## 10. Security and release controls

For both JVM and native variants:

- Run as the non-root user supplied by the buildpack lifecycle.
- Use immutable tags or digests in deployment manifests.
- Generate and retain the application SBOM.
- Sign the published image digest.
- Produce build provenance where the CI platform supports it.
- Scan the final image, not only the builder.
- Record builder, run-image, buildpack, JDK/GraalVM, Spring Boot, Gradle, OS, and architecture versions.
- Rebuild regularly to pick up base-image and toolchain security updates.
- Define a rollback policy between native and JVM variants.

An image with fewer packages can reduce attack surface, but minimalism does not replace patching, signing, least privilege, network policy, secret management, and runtime hardening.

## 11. Direct executable and RPM distribution as a future option

A GraalVM native executable does not technically need a container. Direct Linux packaging can be appropriate for customers that prohibit container runtimes or require conventional host installation.

An RPM distribution would normally need to provide more than the executable:

- A signed architecture-specific package.
- A service user and group.
- A `systemd` service definition.
- Installation, upgrade, rollback, and uninstall behavior.
- Configuration and secret locations.
- Data, temporary, and log-directory ownership.
- Required CA certificates, timezone data, and native libraries.
- Health-check and operational documentation.
- Checksums, SBOM, provenance, and package-signing instructions.

Direct packaging expands the support matrix across CPU architecture, kernel behavior, glibc compatibility, filesystem conventions, service management, security policy, and customer upgrade procedures. It should therefore be treated as a secondary distribution channel after the native OCI image is stable.

For broad host compatibility, build on a deliberately chosen glibc baseline or use a mostly-static strategy, select a conservative CPU target, and test against every supported customer OS generation. An RPM should not simply wrap an arbitrary binary produced on a modern CI runner.

## 12. Alternatives considered

These are bounded exceptions rather than peer recommendations. The Gradle and Paketo Noble Java Tiny workflow remains the default unless a concrete customer or runtime requirement makes it unsuitable.

### Multi-stage Dockerfile with Paketo-independent runtime

**Use when:** custom OS packages, exact filesystem control, or non-Paketo policy requirements are mandatory.

**Trade-off:** maximum control, but the team owns base compatibility, non-root setup, certificate and timezone content, labels, SBOM workflow, architecture handling, and patching.

### `scratch`

**Use when:** the executable is fully static and the application genuinely needs no certificate bundle, timezone database, locale data, shell, or other filesystem assets.

**Trade-off:** smallest theoretical wrapper, but often less operationally convenient and not necessarily smaller in total once required assets are copied back. Fully static musl builds also introduce a different libc choice and compatibility surface.

### Bare executable or RPM

**Use when:** a customer requires host-native installation.

**Trade-off:** removes the container wrapper but transfers service integration and OS compatibility responsibilities to the vendor and customer.

## 13. Final decision statement

The preferred production direction is a **dual Gradle/Paketo pipeline**:

- Continue producing a JVM OCI image with a JRE for compatibility and rollback.
- Add a GraalVM Native Image OCI variant using `paketobuildpacks/builder-noble-java-tiny`.
- Treat the native image as the preferred low-startup, low-memory deployment after qualification.
- Use a custom Dockerfile only when a concrete runtime dependency or customer requirement cannot be satisfied by the supported Paketo path.
- Explore RPM distribution later as a customer-driven secondary channel.

This approach provides the best balance of runtime efficiency, Spring Boot supportability, Gradle integration, minimal image surface, supply-chain visibility, and manageable engineering ownership.

## References

1. Spring Boot, [Developing Your First GraalVM Native Application](https://docs.spring.io/spring-boot/how-to/native-image/developing-your-first-application.html).
2. Spring Boot Gradle Plugin, [Packaging OCI Images](https://docs.spring.io/spring-boot/gradle-plugin/packaging-oci-image.html).
3. Paketo Buildpacks, [Java Native Image Buildpack Reference](https://paketo.io/docs/reference/java-native-image-reference/).
4. Paketo Buildpacks, [How to Build Java Apps with Paketo Buildpacks](https://paketo.io/docs/howto/java/).
5. Paketo Buildpacks, [Noble Java Tiny Builder Releases](https://github.com/paketo-buildpacks/builder-noble-java-tiny/releases).
6. Paketo Buildpacks, [Ubuntu Noble Base Image Releases and CycloneDX Receipts](https://github.com/paketo-buildpacks/ubuntu-noble-base-images/releases).
7. Cloud Native Buildpacks, [`pack builder inspect`](https://buildpacks.io/docs/for-platform-operators/how-to/integrate-ci/pack/cli/pack_builder_inspect/).
8. Cloud Native Buildpacks, [`pack sbom download`](https://buildpacks.io/docs/for-platform-operators/how-to/integrate-ci/pack/cli/pack_sbom_download/).
9. GraalVM, [Native Image Optimizations and Performance](https://www.graalvm.org/jdk25/reference-manual/native-image/optimizations-and-performance/).
10. GraalVM, [Optimize Memory Footprint of a Native Executable](https://www.graalvm.org/jdk25/reference-manual/native-image/guides/optimize-memory-footprint/).
11. GraalVM, [Build Statically or Mostly-Statically Linked Executables](https://www.graalvm.org/jdk25.1/reference-manual/native-image/guides/build-static-executables/).
