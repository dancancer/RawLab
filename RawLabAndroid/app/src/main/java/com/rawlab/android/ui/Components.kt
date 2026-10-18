package com.rawlab.android.ui

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.Text
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat

// ============================================================================
//  各界面共用的小组件：带提示的图标按钮、底部面板的系统栏样式
// ============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ToolIcon(icon: ImageVector, label: Int, enabled: Boolean = true, onClick: () -> Unit) {
    val text = stringResource(label)
    TooltipBox(positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
        tooltip = { PlainTooltip { Text(text) } }, state = rememberTooltipState()) {
        IconButton(onClick = onClick, enabled = enabled) { Icon(icon, text) }
    }
}

@Composable
internal fun EditorSheetSystemBars() {
    val view = LocalView.current
    DisposableEffect(view) {
        val window = (view.parent as? DialogWindowProvider)?.window
        val controller = window?.let { WindowCompat.getInsetsController(it, view) }
        controller?.isAppearanceLightStatusBars = false
        controller?.isAppearanceLightNavigationBars = false
        onDispose { }
    }
}
