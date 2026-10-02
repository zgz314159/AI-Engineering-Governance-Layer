package com.example.governed.domain

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class GreeterTest {
    @Test
    fun `greets a name`() {
        assertEquals("Hello, Ada", Greeter().greet("Ada"))
    }
}
