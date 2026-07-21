package com.example.helloworld

import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get

@SpringBootTest
@AutoConfigureMockMvc
class HelloWorldApplicationTests {
    @Autowired
    lateinit var mockMvc: MockMvc

    @Test
    fun `hello endpoint returns the expected JSON response`() {
        mockMvc.get("/hello")
            .andExpect {
                status { isOk() }
                content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
                content { string("""{"message":"Hello, World!"}""") }
            }
    }
}
