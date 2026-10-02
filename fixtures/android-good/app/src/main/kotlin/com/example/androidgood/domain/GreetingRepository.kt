package com.example.androidgood.domain

fun interface GreetingRepository {
    fun greetingFor(name: String): String
}
