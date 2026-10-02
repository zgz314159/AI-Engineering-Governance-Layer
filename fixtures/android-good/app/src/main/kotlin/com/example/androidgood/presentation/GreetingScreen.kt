package com.example.androidgood.presentation

import androidx.compose.runtime.Composable

@Composable
fun GreetingScreen(viewModel: GreetingViewModel) {
    val message = viewModel.greeting("AEGL")
    println(message)
}
