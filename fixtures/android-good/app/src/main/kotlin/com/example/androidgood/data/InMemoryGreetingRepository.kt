package com.example.androidgood.data

import com.example.androidgood.domain.GreetingRepository

class InMemoryGreetingRepository : GreetingRepository {
    override fun greetingFor(name: String): String = "Hello, $name"
}
