package com.example.governed.data

import com.example.governed.domain.Greeter

class GreeterRepository(
    private val greeter: Greeter = Greeter(),
) {
    fun greetingFor(name: String): String = greeter.greet(name)
}
