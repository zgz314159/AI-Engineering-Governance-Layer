package com.example.governed.presentation

import com.example.governed.domain.Greeter

class GreetingService(
    private val greeter: Greeter = Greeter(),
) {
    fun render(name: String): String = greeter.greet(name)
}
