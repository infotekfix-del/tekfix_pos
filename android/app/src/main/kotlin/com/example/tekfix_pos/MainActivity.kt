package com.example.tekfix_pos

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.telephony.SmsManager
import android.util.Base64
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class MainActivity : FlutterActivity() {
    private val SMS_CHANNEL = "com.example.tekfix_pos/sms"
    private val KEYSTORE_CHANNEL = "com.example.tekfix_pos/keystore"
    private val SMS_PERMISSION_REQUEST = 1001

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ---------------------------------------------------------------------
        // SMS CHANNEL
        // ---------------------------------------------------------------------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sendSms" -> {
                    val phone = call.argument<String>("phone")
                    val message = call.argument<String>("message")
                    if (phone.isNullOrBlank() || message.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "Phone and message cannot be empty", null)
                        return@setMethodCallHandler
                    }

                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
                        result.error("PERMISSION_DENIED", "SEND_SMS permission not granted", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val smsManager: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            applicationContext.getSystemService(SmsManager::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            SmsManager.getDefault()
                        }

                        val parts = smsManager.divideMessage(message)
                        if (parts.size > 1) {
                            smsManager.sendMultipartTextMessage(phone, null, parts, null, null)
                        } else {
                            smsManager.sendTextMessage(phone, null, message, null, null)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SMS_ERROR", e.localizedMessage ?: "Failed to send SMS", null)
                    }
                }
                "hasSmsPermission" -> {
                    val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                }
                "requestSmsPermission" -> {
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.SEND_SMS), SMS_PERMISSION_REQUEST)
                    }
                    result.success(true)
                }
                "isBatteryOptimizationIgnored" -> {
                    val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
                    val isIgnoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && powerManager != null) {
                        powerManager.isIgnoringBatteryOptimizations(packageName)
                    } else {
                        true
                    }
                    result.success(isIgnoring)
                }
                "requestIgnoreBatteryOptimization" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        startActivity(intent)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ---------------------------------------------------------------------
        // PHASE 14.1: HARDWARE KEYSTORE CHANNEL (AndroidKeyStore StrongBox / TEE)
        // ---------------------------------------------------------------------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KEYSTORE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSecurityLevel" -> {
                    try {
                        val hasStrongBox = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
                        } else {
                            false
                        }
                        if (hasStrongBox) {
                            result.success("hardware_strongbox")
                        } else {
                            result.success("hardware_tee")
                        }
                    } catch (e: Exception) {
                        result.success("software_sandboxed")
                    }
                }
                "generateKey" -> {
                    val alias = call.argument<String>("alias") ?: "tekfix_owner_device_key"
                    try {
                        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                        if (keyStore.containsAlias(alias)) {
                            keyStore.deleteEntry(alias)
                        }

                        val kpg = KeyPairGenerator.getInstance(
                            KeyProperties.KEY_ALGORITHM_EC,
                            "AndroidKeyStore"
                        )

                        var isStrongBox = false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                            packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
                        ) {
                            try {
                                val spec = KeyGenParameterSpec.Builder(
                                    alias,
                                    KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
                                )
                                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                                    .setDigests(KeyProperties.DIGEST_SHA256)
                                    .setIsStrongBoxBacked(true)
                                    .build()
                                kpg.initialize(spec)
                                kpg.generateKeyPair()
                                isStrongBox = true
                            } catch (e: Exception) {
                                isStrongBox = false
                            }
                        }

                        if (!isStrongBox) {
                            val spec = KeyGenParameterSpec.Builder(
                                alias,
                                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
                            )
                                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                                .setDigests(KeyProperties.DIGEST_SHA256)
                                .build()
                            kpg.initialize(spec)
                            kpg.generateKeyPair()
                        }

                        val certificate = keyStore.getCertificate(alias)
                        val publicKey = certificate.publicKey
                        val pubBase64 = Base64.encodeToString(publicKey.encoded, Base64.NO_WRAP)
                        val pubPem = "-----BEGIN PUBLIC KEY-----\n$pubBase64\n-----END PUBLIC KEY-----"

                        result.success(mapOf(
                            "publicKeyPem" to pubPem,
                            "securityLevel" to if (isStrongBox) "hardware_strongbox" else "hardware_tee"
                        ))
                    } catch (e: Exception) {
                        result.error("KEYGEN_FAILED", e.localizedMessage, null)
                    }
                }
                "signPayload" -> {
                    val alias = call.argument<String>("alias") ?: "tekfix_owner_device_key"
                    val payloadBytes = call.argument<ByteArray>("payload")
                    if (payloadBytes == null) {
                        result.error("INVALID_ARGS", "Payload cannot be null", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                        val privateKey = keyStore.getKey(alias, null) as? java.security.PrivateKey
                        if (privateKey == null) {
                            result.error("KEY_NOT_FOUND", "Private key not found for alias: $alias", null)
                            return@setMethodCallHandler
                        }

                        val s = Signature.getInstance("SHA256withECDSA")
                        s.initSign(privateKey)
                        s.update(payloadBytes)
                        val signatureBytes = s.sign()
                        val sigBase64 = Base64.encodeToString(signatureBytes, Base64.NO_WRAP)
                        result.success(sigBase64)
                    } catch (e: Exception) {
                        result.error("SIGN_FAILED", e.localizedMessage, null)
                    }
                }
                "deleteKey" -> {
                    val alias = call.argument<String>("alias") ?: "tekfix_owner_device_key"
                    try {
                        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                        if (keyStore.containsAlias(alias)) {
                            keyStore.deleteEntry(alias)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("DELETE_FAILED", e.localizedMessage, null)
                    }
                }
                "hasKey" -> {
                    val alias = call.argument<String>("alias") ?: "tekfix_owner_device_key"
                    try {
                        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                        result.success(keyStore.containsAlias(alias))
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "getDeviceHardwareInfo" -> {
                    try {
                        val hasStrongBox = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
                        } else {
                            false
                        }
                        val securityPatch = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            Build.VERSION.SECURITY_PATCH
                        } else {
                            "legacy"
                        }
                        result.success(mapOf(
                            "manufacturer" to Build.MANUFACTURER,
                            "model" to Build.MODEL,
                            "brand" to Build.BRAND,
                            "device" to Build.DEVICE,
                            "androidVersion" to Build.VERSION.RELEASE,
                            "sdkInt" to Build.VERSION.SDK_INT,
                            "securityPatch" to securityPatch,
                            "hasStrongBoxFeature" to hasStrongBox
                        ))
                    } catch (e: Exception) {
                        result.error("DEVICE_INFO_ERROR", e.localizedMessage, null)
                    }
                }
                "verifyPrivateKeyNonExtractable" -> {
                    val alias = call.argument<String>("alias") ?: "tekfix_owner_device_key"
                    try {
                        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                        val privateKey = keyStore.getKey(alias, null) as? java.security.PrivateKey
                        if (privateKey == null) {
                            result.error("KEY_NOT_FOUND", "Private key not found for alias: $alias", null)
                            return@setMethodCallHandler
                        }
                        val encoded = privateKey.encoded
                        val isNonExtractable = (encoded == null)
                        val keyFactory = KeyFactory.getInstance(privateKey.algorithm, "AndroidKeyStore")
                        val keyInfo = keyFactory.getKeySpec(privateKey, KeyInfo::class.java) as KeyInfo
                        val isInsideSecureHardware = keyInfo.isInsideSecureHardware

                        val securityLevelStr = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            when (keyInfo.securityLevel) {
                                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "STRONGBOX_BACKED"
                                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "TEE_BACKED"
                                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "SOFTWARE_BACKED"
                                else -> if (isInsideSecureHardware) "TEE_BACKED" else "SOFTWARE_BACKED"
                            }
                        } else {
                            if (isInsideSecureHardware) "TEE_BACKED" else "SOFTWARE_BACKED"
                        }

                        result.success(mapOf(
                            "isNonExtractable" to isNonExtractable,
                            "format" to (privateKey.format ?: "NONE"),
                            "algorithm" to privateKey.algorithm,
                            "isInsideSecureHardware" to isInsideSecureHardware,
                            "securityLevel" to securityLevelStr
                        ))
                    } catch (e: Exception) {
                        result.error("EXTRACTION_TEST_FAILED", e.localizedMessage, null)
                    }
                }
                "verifySignatureNatively" -> {
                    val alias = call.argument<String>("alias") ?: "tekfix_owner_device_key"
                    val payloadBytes = call.argument<ByteArray>("payload")
                    val sigInput = call.argument<String>("signatureBase64") ?: call.argument<String>("signature")
                    if (payloadBytes == null || sigInput == null) {
                        result.error("INVALID_ARGS", "Payload and signatureBase64 required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                        val cert = keyStore.getCertificate(alias)
                        if (cert == null) {
                            result.error("CERT_NOT_FOUND", "Certificate not found for alias: $alias", null)
                            return@setMethodCallHandler
                        }
                        val trimmed = sigInput.trim()
                        val sigBytes = try {
                            if (trimmed.startsWith("30") && trimmed.matches(Regex("^[0-9a-fA-F]+$")) && trimmed.length % 2 == 0) {
                                trimmed.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
                            } else {
                                Base64.decode(trimmed, Base64.NO_WRAP)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val isValid = try {
                            val verifier = Signature.getInstance("SHA256withECDSA")
                            verifier.initVerify(cert.publicKey)
                            verifier.update(payloadBytes)
                            verifier.verify(sigBytes)
                        } catch (e: Exception) {
                            false
                        }
                        result.success(isValid)
                    } catch (e: Exception) {
                        result.error("VERIFY_FAILED", e.localizedMessage, null)
                    }
                }
                "shareTextReport" -> {
                    val reportText = call.argument<String>("reportText")
                    val title = call.argument<String>("title") ?: "TekFix Audit Report"
                    if (reportText.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "reportText cannot be empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val sendIntent = Intent().apply {
                            action = Intent.ACTION_SEND
                            putExtra(Intent.EXTRA_TEXT, reportText)
                            putExtra(Intent.EXTRA_SUBJECT, title)
                            type = "text/plain"
                        }
                        val shareIntent = Intent.createChooser(sendIntent, title)
                        shareIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(shareIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.localizedMessage, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
