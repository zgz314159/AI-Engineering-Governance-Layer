package com.example.baddomain.presentation

import com.example.baddomain.domain.ContextGreeter

class GreeterScreen(
    private val greeter: ContextGreeter,
) {
    fun label(): String = greeter.appLabel()
}
