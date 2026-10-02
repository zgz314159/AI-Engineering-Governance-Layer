package com.example.androidgood.domain

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class GreetingUseCaseTest {
    @Test
    fun `message delegates to the repository`() {
        val useCase = GreetingUseCase(GreetingRepository { name -> "Hello, $name" })
        assertEquals("Hello, AEGL", useCase.message("AEGL"))
    }
}
