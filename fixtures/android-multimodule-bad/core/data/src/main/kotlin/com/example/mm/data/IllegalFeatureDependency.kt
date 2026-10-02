package com.example.mm.data

import com.example.mm.feature.sample.SampleViewModel

class IllegalFeatureDependency {
    fun userName(viewModel: SampleViewModel): String = viewModel.userName(1L)
}
