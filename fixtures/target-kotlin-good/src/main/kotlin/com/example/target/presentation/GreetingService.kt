package com.example.target.presentation

import com.example.target.domain.Greeter

class GreetingService(
    private val greeter: Greeter = Greeter(),
) {
    fun render(name: String): String = greeter.greet(name)
}
