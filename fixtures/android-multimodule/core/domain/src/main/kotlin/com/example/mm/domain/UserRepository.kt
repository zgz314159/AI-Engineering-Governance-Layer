package com.example.mm.domain

interface UserRepository {
    fun load(id: Long): User?
}
