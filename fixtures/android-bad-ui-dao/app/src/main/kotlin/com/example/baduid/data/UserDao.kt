package com.example.baduid.data

import androidx.room.Dao
import androidx.room.Query

@Dao
interface UserDao {
    @Query("SELECT name FROM users WHERE id = :id")
    fun nameOf(id: Long): String?
}
