package com.rawlab.android.editor.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.ImeAction
import com.rawlab.android.R
import com.rawlab.android.looks.LookBrowserCategory

internal fun LookBrowserCategory.title() = when (this) {
    LookBrowserCategory.ALL -> R.string.look_category_all
    LookBrowserCategory.FUJI -> R.string.look_category_fuji
    LookBrowserCategory.KODAK -> R.string.look_category_kodak
    LookBrowserCategory.OTHER -> R.string.look_category_other
    LookBrowserCategory.CUSTOM -> R.string.look_category_custom
    LookBrowserCategory.RECENT -> R.string.look_category_recent
}

@Composable
internal fun LookBrowserControls(category: LookBrowserCategory, onCategory: (LookBrowserCategory) -> Unit,
    query: String, onQuery: (String) -> Unit, canImport: Boolean, onImport: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.padding(horizontal = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(query, onQuery, Modifier.weight(1f).testTag("looks.search"), singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                placeholder = { Text(stringResource(R.string.look_search)) },
                leadingIcon = { Icon(Icons.Outlined.Search, null) },
                trailingIcon = { if (query.isNotEmpty()) IconButton({ onQuery("") }, Modifier.size(48.dp).testTag("looks.search.clear")) {
                    Icon(Icons.Outlined.Close, stringResource(R.string.look_search_clear))
                } })
            IconButton(onImport, Modifier.size(48.dp).testTag("looks.import"), enabled = canImport) {
                Icon(Icons.Outlined.Add, stringResource(R.string.import_look))
            }
        }
        Box {
            TextButton({ expanded = true }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("looks.category")) {
                Text(stringResource(category.title()), Modifier.weight(1f))
                Icon(Icons.Outlined.ExpandMore, stringResource(R.string.look_category))
            }
            DropdownMenu(expanded, { expanded = false }) {
                LookBrowserCategory.entries.forEach { item ->
                    DropdownMenuItem(text = { Text(stringResource(item.title())) },
                        leadingIcon = { if (category == item) Icon(Icons.Outlined.Check, null) },
                        onClick = { onCategory(item); expanded = false }, modifier = Modifier.testTag("looks.category.${item.name}"))
                }
            }
        }
    }
}
