package com.example.target.domain

import com.example.target.presentation.GreetingService

class IllegalDependency {
    fun render(service: GreetingService, name: String): String = service.render(name)
}
