package com.example.target.data

import com.example.target.domain.Greeter

class GreeterRepository(
    private val greeter: Greeter = Greeter(),
) {
    fun greetingFor(name: String): String = greeter.greet(name)
}
