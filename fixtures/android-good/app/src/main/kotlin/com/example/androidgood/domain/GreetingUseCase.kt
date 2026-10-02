package com.example.androidgood.domain

class GreetingUseCase(
    private val repository: GreetingRepository,
) {
    fun message(name: String): String = repository.greetingFor(name)
}
