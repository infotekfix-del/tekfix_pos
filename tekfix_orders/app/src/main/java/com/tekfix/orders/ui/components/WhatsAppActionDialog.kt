package com.tekfix.orders.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.tekfix.orders.data.model.Order
import com.tekfix.orders.service.WhatsAppIntegrationService
import com.tekfix.orders.service.WhatsAppMessageFormatter
import com.tekfix.orders.ui.theme.TekfixGreen
import com.tekfix.orders.ui.theme.WhatsAppDarkGreen
import com.tekfix.orders.ui.theme.WhatsAppGreen

@Composable
fun WhatsAppActionDialog(
    order: Order,
    groupInvitationUrl: String = "https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4",
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val service = remember { WhatsAppIntegrationService(context) }
    val formattedMessage = remember(order) { WhatsAppMessageFormatter.formatOrderMessage(order) }
    var copied by remember { mutableStateOf(false) }

    Dialog(onDismissRequest = onDismiss) {
        Card(
            shape = RoundedCornerShape(24.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            elevation = CardDefaults.cardElevation(defaultElevation = 8.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(8.dp)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp)
                    .verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Box(
                    modifier = Modifier
                        .size(64.dp)
                        .clip(CircleShape)
                        .background(WhatsAppGreen.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Default.CheckCircle,
                        contentDescription = "Success",
                        tint = WhatsAppDarkGreen,
                        modifier = Modifier.size(36.dp)
                    )
                }

                Spacer(modifier = Modifier.height(16.dp))

                Text(
                    text = "ഓർഡർ രേഖപ്പെടുത്തി!",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = "Order Saved Successfully",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                Spacer(modifier = Modifier.height(8.dp))

                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Text(
                        text = "ID: ${order.orderId}",
                        fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.labelMedium,
                        color = TekfixGreen,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
                    )
                }

                Spacer(modifier = Modifier.height(16.dp))

                Text(
                    text = "ഓർഡർ ഡാറ്റാബേസിൽ സുരക്ഷിതമായി സേവ് ചെയ്തു. താഴെ കാണുന്ന ബട്ടൺ വഴി ഓർഡർ വാട്സാപ്പ് ഗ്രൂപ്പിലേക്ക് അയക്കുക.\n(Order is saved in database. Share to company WhatsApp group below).",
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    lineHeight = 18.sp
                )

                Spacer(modifier = Modifier.height(20.dp))

                // Action 1: Copy Order Text
                OutlinedButton(
                    onClick = {
                        service.copyOrderToClipboard(formattedMessage)
                        copied = true
                    },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = if (copied) WhatsAppDarkGreen else MaterialTheme.colorScheme.onSurface
                    )
                ) {
                    Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = if (copied) "ഓർഡർ കോപ്പി ചെയ്തു ✓" else "ഓർഡർ കോപ്പി ചെയ്യുക (Copy Order Text)",
                        fontWeight = FontWeight.SemiBold
                    )
                }

                Spacer(modifier = Modifier.height(10.dp))

                // Action 2: Open WhatsApp Group Invitation
                Button(
                    onClick = {
                        // Automatically copy text first if not yet copied
                        if (!copied) {
                            service.copyOrderToClipboard(formattedMessage)
                            copied = true
                        }
                        service.openGroupInvitation(groupInvitationUrl)
                    },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = WhatsAppGreen)
                ) {
                    Icon(Icons.Default.Groups, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "വാട്സാപ്പ് ഗ്രൂപ്പ് തുറക്കുക (Open WhatsApp Group)",
                        fontWeight = FontWeight.Bold,
                        color = Color.White
                    )
                }

                Spacer(modifier = Modifier.height(10.dp))

                // Action 3: Share sheet fallback
                TextButton(
                    onClick = { service.shareOrderText(formattedMessage) },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Default.Share, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("മറ്റ് ആപ്പുകളിലേക്ക് ഷെയർ ചെയ്യുക (Share via other apps)")
                }

                Spacer(modifier = Modifier.height(12.dp))

                Button(
                    onClick = onDismiss,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    Text("പൂർത്തിയായി (Done)", color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}
