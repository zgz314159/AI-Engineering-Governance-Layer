package com.example.androidgood.presentation

import androidx.lifecycle.ViewModel
import com.example.androidgood.domain.GreetingUseCase

class GreetingViewModel(
    private val useCase: GreetingUseCase,
) : ViewModel() {
    fun greeting(name: String): String = useCase.message(name)
}
