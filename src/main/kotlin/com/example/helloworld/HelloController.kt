package com.example.helloworld

import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RestController

@RestController
class HelloController {
    @GetMapping("/hello")
    fun hello() = Greeting(message = "Hello, World!")
}

data class Greeting(
    val message: String,
)
