import org.springframework.boot.gradle.tasks.bundling.BootBuildImage

plugins {
    kotlin("jvm") version "2.3.21"
    kotlin("plugin.spring") version "2.3.21"
    id("org.springframework.boot") version "4.1.0"
    id("io.spring.dependency-management") version "1.1.7"
    id("org.graalvm.buildtools.native") version "1.1.1" apply false
}

group = "com.example"
version = "0.0.1-SNAPSHOT"
description = "Minimal Spring Boot example that produces JVM and GraalVM native OCI images"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(25)
    }
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-webmvc")
    implementation("org.jetbrains.kotlin:kotlin-reflect")
    implementation("tools.jackson.module:jackson-module-kotlin")

    testImplementation("org.springframework.boot:spring-boot-starter-webmvc-test")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit5")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

kotlin {
    compilerOptions {
        freeCompilerArgs.addAll(
            "-Xjsr305=strict",
            "-Xannotation-default-target=param-property",
        )
    }
}

tasks.withType<Test> {
    useJUnitPlatform()
}

val nativeImageRequested = providers.gradleProperty("nativeImage").isPresent

if (nativeImageRequested) {
    apply(plugin = "org.graalvm.buildtools.native")
}

tasks.named<BootBuildImage>("bootBuildImage") {
    val imageVariant = if (nativeImageRequested) "native" else "jvm"

    builder.set("paketobuildpacks/builder-noble-java-tiny:0.0.160")
    imageName.set("hello-world:${project.version}-$imageVariant")
    environment.put("BP_JVM_VERSION", "25")

    if (nativeImageRequested) {
        environment.put("BP_NATIVE_IMAGE_BUILD_ARGUMENTS", "-march=compatibility")
    }
}
