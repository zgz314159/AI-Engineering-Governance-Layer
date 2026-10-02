package com.example.mm.feature.sample

import com.example.mm.domain.UserRepository

class SampleViewModel(
    private val repository: UserRepository,
) {
    fun userName(id: Long): String = repository.load(id)?.name ?: "unknown"
}
