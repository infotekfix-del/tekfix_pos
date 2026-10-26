package com.tekfix.orders.ui.navigation

sealed class Screen(val route: String) {
    object Splash : Screen("splash")
    object Login : Screen("login")

    // Staff Flow
    object StaffDashboard : Screen("staff_dashboard")
    object NewOrder : Screen("new_order")
    object OrderCart : Screen("order_cart")
    object OrderPreview : Screen("order_preview")
    object OrderHistory : Screen("order_history")
    object OrderDetail : Screen("order_detail/{orderId}") {
        fun createRoute(orderId: String) = "order_detail/$orderId"
    }

    // Admin Flow
    object AdminDashboard : Screen("admin_dashboard")
    object ProductManagement : Screen("admin_products")
    object StaffManagement : Screen("admin_staff")
    object Reports : Screen("admin_reports")
    object WhatsAppSettings : Screen("admin_whatsapp_settings")
}
