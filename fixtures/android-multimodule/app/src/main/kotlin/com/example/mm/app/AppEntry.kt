package com.example.mm.app

import com.example.mm.data.UserRepositoryImpl
import com.example.mm.feature.sample.SampleViewModel

class AppEntry {
    fun greeting(id: Long): String {
        val viewModel = SampleViewModel(UserRepositoryImpl())
        return viewModel.userName(id)
    }
}
