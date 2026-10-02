package com.example.baddomain.domain

import android.content.Context

class ContextGreeter(
    private val context: Context,
) {
    fun appLabel(): String = context.packageName
}
