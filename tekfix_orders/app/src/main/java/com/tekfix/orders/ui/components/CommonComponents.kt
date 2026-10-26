package com.tekfix.orders.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tekfix.orders.data.model.OrderStatus
import com.tekfix.orders.data.model.WhatsAppStatus
import com.tekfix.orders.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TekfixTopAppBar(
    title: String,
    subtitle: String? = null,
    canNavigateBack: Boolean = false,
    onNavigateBack: () -> Unit = {},
    isOffline: Boolean = false,
    actions: @Composable RowScope.() -> Unit = {}
) {
    TopAppBar(
        title = {
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = Color.White
                    )
                    if (isOffline) {
                        Spacer(modifier = Modifier.width(8.dp))
                        Icon(
                            imageVector = Icons.Default.WifiOff,
                            contentDescription = "Offline",
                            tint = Color(0xFFFBBF24),
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
                if (subtitle != null) {
                    Text(
                        text = subtitle,
                        style = MaterialTheme.typography.labelMedium,
                        color = Color.White.copy(alpha = 0.8f)
                    )
                }
            }
        },
        navigationIcon = {
            if (canNavigateBack) {
                IconButton(onClick = onNavigateBack) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        tint = Color.White
                    )
                }
            }
        },
        actions = actions,
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = TekfixDarkGreen,
            titleContentColor = Color.White,
            actionIconContentColor = Color.White
        )
    )
}

@Composable
fun StatCard(
    title: String,
    value: String,
    icon: ImageVector,
    iconColor: Color,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null
) {
    Card(
        modifier = modifier
            .then(if (onClick != null) Modifier.clickable { onClick() } else Modifier),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(iconColor.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = iconColor,
                    modifier = Modifier.size(24.dp)
                )
            }
            Spacer(modifier = Modifier.width(14.dp))
            Column {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = value,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
        }
    }
}

@Composable
fun OrderStatusBadge(status: OrderStatus) {
    val (badgeBg, badgeText) = when (status) {
        OrderStatus.SUBMITTED -> StatusSubmitted.copy(alpha = 0.15f) to StatusSubmitted
        OrderStatus.PENDING -> StatusPending.copy(alpha = 0.15f) to StatusPending
        OrderStatus.CONFIRMED -> StatusConfirmed.copy(alpha = 0.15f) to StatusConfirmed
        OrderStatus.PROCESSING -> StatusProcessing.copy(alpha = 0.15f) to StatusProcessing
        OrderStatus.COMPLETED -> StatusCompleted.copy(alpha = 0.15f) to StatusCompleted
        OrderStatus.CANCELLED -> StatusCancelled.copy(alpha = 0.15f) to StatusCancelled
        OrderStatus.DRAFT -> StatusDraft.copy(alpha = 0.15f) to StatusDraft
    }

    Surface(
        color = badgeBg,
        shape = RoundedCornerShape(12.dp)
    ) {
        Text(
            text = status.displayName,
            color = badgeText,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
        )
    }
}

@Composable
fun WhatsAppStatusBadge(status: WhatsAppStatus) {
    val (badgeBg, badgeText) = when (status) {
        WhatsAppStatus.SENT_SUCCESSFULLY -> WhatsAppGreen.copy(alpha = 0.15f) to WhatsAppDarkGreen
        WhatsAppStatus.WAITING_DELIVERY -> StatusPending.copy(alpha = 0.15f) to StatusPending
        WhatsAppStatus.DELIVERY_FAILED -> StatusCancelled.copy(alpha = 0.15f) to StatusCancelled
        WhatsAppStatus.ORDER_SAVED,
        WhatsAppStatus.MANUAL_ACTION_REQUIRED -> WhatsAppTeal.copy(alpha = 0.12f) to WhatsAppTeal
    }

    Surface(
        color = badgeBg,
        shape = RoundedCornerShape(12.dp)
    ) {
        Text(
            text = "WA: ${status.displayName}",
            color = badgeText,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
        )
    }
}

@Composable
fun TekfixSearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    placeholder: String = "Search products or SKU...",
    modifier: Modifier = Modifier
) {
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        placeholder = { Text(placeholder, style = MaterialTheme.typography.bodyMedium) },
        leadingIcon = { Icon(Icons.Default.Search, contentDescription = "Search") },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQueryChange("") }) {
                    Icon(Icons.Default.Clear, contentDescription = "Clear")
                }
            }
        },
        singleLine = true,
        shape = RoundedCornerShape(14.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surface,
            unfocusedContainerColor = MaterialTheme.colorScheme.surface,
            focusedBorderColor = TekfixGreen,
            unfocusedBorderColor = CardBorder
        ),
        modifier = modifier.fillMaxWidth()
    )
}

@Composable
fun EmptyStateView(
    icon: ImageVector,
    title: String,
    subtitle: String,
    actionButtonText: String? = null,
    onActionClick: () -> Unit = {}
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(TekfixLightGreen),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = TekfixGreen,
                modifier = Modifier.size(36.dp)
            )
        }
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(modifier = Modifier.height(6.dp))
        Text(
            text = subtitle,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center
        )
        if (actionButtonText != null) {
            Spacer(modifier = Modifier.height(20.dp))
            Button(
                onClick = onActionClick,
                colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                shape = RoundedCornerShape(12.dp)
            ) {
                Text(actionButtonText, fontWeight = FontWeight.Bold)
            }
        }
    }
}
