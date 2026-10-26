package com.tekfix.orders.ui.navigation

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.tekfix.orders.data.model.User
import com.tekfix.orders.ui.admin.*
import com.tekfix.orders.ui.auth.AuthViewModel
import com.tekfix.orders.ui.auth.LoginScreen
import com.tekfix.orders.ui.auth.SplashScreen
import com.tekfix.orders.ui.staff.*
import com.tekfix.orders.util.NetworkMonitor

@Composable
fun AppNavigation(
    navController: NavHostController = rememberNavController(),
    authViewModel: AuthViewModel = remember { AuthViewModel() }
) {
    val context = LocalContext.current
    val networkMonitor = remember { NetworkMonitor(context) }
    val isOnline by networkMonitor.isOnline.collectAsState(initial = true)
    val isOffline = !isOnline

    val authState by authViewModel.uiState.collectAsState()
    val currentUser = authState.currentUser ?: User()

    val orderViewModel = remember { OrderViewModel(context) }
    val adminViewModel = remember { AdminViewModel() }

    NavHost(
        navController = navController,
        startDestination = Screen.Splash.route
    ) {
        // --- Auth Destinations ---
        composable(Screen.Splash.route) {
            SplashScreen(
                authViewModel = authViewModel,
                onNavigateToStaffDashboard = {
                    navController.navigate(Screen.StaffDashboard.route) {
                        popUpTo(Screen.Splash.route) { inclusive = true }
                    }
                },
                onNavigateToAdminDashboard = {
                    navController.navigate(Screen.AdminDashboard.route) {
                        popUpTo(Screen.Splash.route) { inclusive = true }
                    }
                },
                onNavigateToLogin = {
                    navController.navigate(Screen.Login.route) {
                        popUpTo(Screen.Splash.route) { inclusive = true }
                    }
                }
            )
        }

        composable(Screen.Login.route) {
            LoginScreen(
                authViewModel = authViewModel,
                onNavigateToStaffDashboard = {
                    navController.navigate(Screen.StaffDashboard.route) {
                        popUpTo(Screen.Login.route) { inclusive = true }
                    }
                },
                onNavigateToAdminDashboard = {
                    navController.navigate(Screen.AdminDashboard.route) {
                        popUpTo(Screen.Login.route) { inclusive = true }
                    }
                }
            )
        }

        // --- Staff Destinations ---
        composable(Screen.StaffDashboard.route) {
            StaffDashboardScreen(
                currentUser = currentUser,
                orderViewModel = orderViewModel,
                onNavigateToNewOrder = { navController.navigate(Screen.NewOrder.route) },
                onNavigateToOrderHistory = { navController.navigate(Screen.OrderHistory.route) },
                onNavigateToOrderDetail = { id -> navController.navigate(Screen.OrderDetail.createRoute(id)) },
                onLogout = {
                    authViewModel.logout {
                        navController.navigate(Screen.Login.route) {
                            popUpTo(0) { inclusive = true }
                        }
                    }
                },
                isOffline = isOffline
            )
        }

        composable(Screen.NewOrder.route) {
            NewOrderScreen(
                currentUser = currentUser,
                orderViewModel = orderViewModel,
                onNavigateBack = { navController.popBackStack() },
                onNavigateToCart = { navController.navigate(Screen.OrderCart.route) },
                isOffline = isOffline
            )
        }

        composable(Screen.OrderCart.route) {
            OrderCartScreen(
                orderViewModel = orderViewModel,
                onNavigateBack = { navController.popBackStack() },
                onNavigateToPreview = { navController.navigate(Screen.OrderPreview.route) },
                isOffline = isOffline
            )
        }

        composable(Screen.OrderPreview.route) {
            OrderPreviewScreen(
                orderViewModel = orderViewModel,
                onNavigateBack = { navController.popBackStack() },
                onNavigateToDashboard = {
                    navController.navigate(Screen.StaffDashboard.route) {
                        popUpTo(Screen.StaffDashboard.route) { inclusive = true }
                    }
                },
                isOffline = isOffline
            )
        }

        composable(Screen.OrderHistory.route) {
            OrderHistoryScreen(
                currentUser = currentUser,
                orderViewModel = orderViewModel,
                onNavigateBack = { navController.popBackStack() },
                onNavigateToOrderDetail = { id -> navController.navigate(Screen.OrderDetail.createRoute(id)) },
                onNavigateToNewOrder = { navController.navigate(Screen.NewOrder.route) },
                isOffline = isOffline
            )
        }

        composable(
            route = Screen.OrderDetail.route,
            arguments = listOf(navArgument("orderId") { type = NavType.StringType })
        ) { backStackEntry ->
            val orderId = backStackEntry.arguments?.getString("orderId") ?: ""
            OrderDetailScreen(
                orderId = orderId,
                currentUser = currentUser,
                orderViewModel = orderViewModel,
                onNavigateBack = { navController.popBackStack() },
                onNavigateToNewOrder = { navController.navigate(Screen.NewOrder.route) },
                isOffline = isOffline
            )
        }

        // --- Admin Destinations ---
        composable(Screen.AdminDashboard.route) {
            AdminDashboardScreen(
                currentUser = currentUser,
                adminViewModel = adminViewModel,
                onNavigateToProducts = { navController.navigate(Screen.ProductManagement.route) },
                onNavigateToStaff = { navController.navigate(Screen.StaffManagement.route) },
                onNavigateToReports = { navController.navigate(Screen.Reports.route) },
                onNavigateToWhatsAppSettings = { navController.navigate(Screen.WhatsAppSettings.route) },
                onNavigateToOrderDetail = { id -> navController.navigate(Screen.OrderDetail.createRoute(id)) },
                onLogout = {
                    authViewModel.logout {
                        navController.navigate(Screen.Login.route) {
                            popUpTo(0) { inclusive = true }
                        }
                    }
                },
                isOffline = isOffline
            )
        }

        composable(Screen.ProductManagement.route) {
            ProductManagementScreen(
                adminViewModel = adminViewModel,
                onNavigateBack = { navController.popBackStack() },
                isOffline = isOffline
            )
        }

        composable(Screen.StaffManagement.route) {
            StaffManagementScreen(
                adminViewModel = adminViewModel,
                onNavigateBack = { navController.popBackStack() },
                isOffline = isOffline
            )
        }

        composable(Screen.Reports.route) {
            ReportsScreen(
                adminViewModel = adminViewModel,
                onNavigateBack = { navController.popBackStack() },
                isOffline = isOffline
            )
        }

        composable(Screen.WhatsAppSettings.route) {
            WhatsAppSettingsScreen(
                adminViewModel = adminViewModel,
                onNavigateBack = { navController.popBackStack() },
                isOffline = isOffline
            )
        }
    }
}
