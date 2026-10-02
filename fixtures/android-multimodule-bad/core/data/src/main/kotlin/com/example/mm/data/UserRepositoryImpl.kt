package com.example.mm.data

import com.example.mm.domain.User
import com.example.mm.domain.UserRepository

class UserRepositoryImpl : UserRepository {
    override fun load(id: Long): User? = User(id, "user-$id")
}
