package com.example.baduid.presentation

import androidx.compose.runtime.Composable
import com.example.baduid.data.UserDao

@Composable
fun UserScreen(userDao: UserDao) {
    val name = userDao.nameOf(1L)
    println(name)
}
