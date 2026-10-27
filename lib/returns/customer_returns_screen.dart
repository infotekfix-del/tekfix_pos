import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show Db, toast;
import '../ui/dashboard/dashboard_tokens.dart';
import 'return_models.dart';
import 'return_service.dart';
import 'return_details_screen.dart';

/// Dedicated Customer Returns screen.
/// Allows staff to search customers by phone number, retrieve historical purchases,
/// check warranty calculations, select a purchased item, and register a return case.
class CustomerReturnsScreen extends StatefulWidget {
  final String? initialPhone;

  const CustomerReturnsScreen({
    super.key,
    this.initialPhone,
  });

  @override
  State<CustomerReturnsScreen> createState() => _CustomerReturnsScreenState();
}

class _CustomerReturnsScreenState extends State<CustomerReturnsScreen> {
  final _phoneCtrl = TextEditingController();
  final _dateFormat = DateFormat('dd MMM yyyy, hh:mm a');
  final _shortDateFormat = DateFormat('dd MMM yyyy');

  List<Map<String, dynamic>> _matchingCustomers = [];
  Map<String, dynamic>? _selectedCustomer;
  List<PurchasedProductItem> _purchasedProducts = [];
  bool _searching = false;
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialPhone != null && widget.initialPhone!.isNotEmpty) {
      _phoneCtrl.text = widget.initialPhone!;
      _performSearch(widget.initialPhone!);
    }
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  void _performSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _matchingCustomers = [];
        _selectedCustomer = null;
        _purchasedProducts = [];
        _hasSearched = false;
      });
      return;
    }

    setState(() {
      _searching = true;
      _hasSearched = true;
    });

    final matches = ReturnService.instance.searchCustomers(q);
    setState(() {
      _searching = false;
      _matchingCustomers = matches;
      if (matches.length == 1) {
        _selectCustomer(matches.first);
      } else if (matches.isEmpty) {
        _selectedCustomer = null;
        // Even if customer party is not explicitly found, check sales for this phone
        final products = ReturnService.instance.getPurchasedProductsByPhone(q);
        _purchasedProducts = products;
        if (products.isNotEmpty) {
          _selectedCustomer = {
            'name': products.first.customerName,
            'phone': products.first.customerPhone,
            'id': 'PURCHASE-RECORD',
            'balance': 0.0,
            'source': 'sales',
          };
        }
      } else {
        _selectedCustomer = null;
        _purchasedProducts = [];
      }
    });
  }

  void _selectCustomer(Map<String, dynamic> cust) {
    setState(() {
      _selectedCustomer = cust;
      _purchasedProducts = ReturnService.instance.getPurchasedProductsByPhone(
        cust['phone']?.toString() ?? '',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DashboardColors.bgDarkNavyStart,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0C1236),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: DashboardColors.activePillGradient,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.assignment_return_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Customer Return & Warranty Registration',
                  style: DashboardTypography.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Search customer by phone number to load verified sales records',
                  style: DashboardTypography.inter(
                    fontSize: 11.5,
                    color: DashboardColors.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: DashboardColors.backgroundGradient,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Search Header Card
              _buildSearchCard(),

              const SizedBox(height: 20),

              // Matching Customers Selector (if multiple)
              if (_matchingCustomers.length > 1) ...[
                _buildCustomerSelectionGrid(),
                const SizedBox(height: 20),
              ],

              // Customer Summary Banner
              if (_selectedCustomer != null) ...[
                _buildCustomerSummaryBanner(),
                const SizedBox(height: 24),
              ],

              // Purchased Products Section
              if (_hasSearched) ...[
                _buildProductsSection(),
              ] else ...[
                _buildSearchGuide(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SEARCH CARD
  // ---------------------------------------------------------------------------

  Widget _buildSearchCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(
        glow: true,
        glowColor: DashboardColors.neonBlue,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.phone_in_talk_rounded, color: DashboardColors.neonBlue, size: 22),
              const SizedBox(width: 10),
              Text(
                '1. SEARCH CUSTOMER BY PHONE NUMBER',
                style: DashboardTypography.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: DashboardColors.neonBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 50,
                  decoration: BoxDecoration(
                    color: const Color(0x33000000),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: DashboardColors.glassBorderHover),
                  ),
                  child: TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    style: DashboardTypography.inter(color: Colors.white, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Enter Customer Mobile Number (e.g. 9876543210)',
                      hintStyle: DashboardTypography.inter(color: DashboardColors.textMuted, fontSize: 13.5),
                      prefixIcon: const Icon(Icons.search_rounded, color: DashboardColors.neonBlue),
                      suffixIcon: _phoneCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, color: DashboardColors.textMuted, size: 18),
                              onPressed: () {
                                _phoneCtrl.clear();
                                _performSearch('');
                              },
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                    onSubmitted: _performSearch,
                    onChanged: (val) {
                      if (val.length >= 4) {
                        _performSearch(val);
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: DashboardColors.primaryBlue,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
                ),
                onPressed: () => _performSearch(_phoneCtrl.text),
                icon: _searching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.search_rounded, size: 20),
                label: Text(
                  'Search',
                  style: DashboardTypography.poppins(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // MULTIPLE CUSTOMERS SELECTION GRID
  // ---------------------------------------------------------------------------

  Widget _buildCustomerSelectionGrid() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: DashboardColors.glassCard(
        borderColor: DashboardColors.neonPurple.withValues(alpha: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.people_alt_rounded, color: DashboardColors.neonPurple, size: 20),
              const SizedBox(width: 8),
              Text(
                'Multiple Customer Matches Found - Please Select One',
                style: DashboardTypography.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: DashboardColors.neonPurple,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: _matchingCustomers.map((cust) {
              final isSelected = _selectedCustomer?['phone'] == cust['phone'] &&
                  _selectedCustomer?['name'] == cust['name'];
              return InkWell(
                onTap: () => _selectCustomer(cust),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? DashboardColors.neonPurple.withValues(alpha: 0.25)
                        : const Color(0x1AFFFFFF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? DashboardColors.neonPurple
                          : const Color(0x26FFFFFF),
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSelected ? Icons.check_circle_rounded : Icons.person_rounded,
                        color: isSelected ? DashboardColors.neonPurple : DashboardColors.textMuted,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cust['name'] ?? 'Unknown',
                            style: DashboardTypography.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            cust['phone'] ?? '',
                            style: DashboardTypography.inter(
                              fontSize: 11,
                              color: DashboardColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // CUSTOMER SUMMARY BANNER
  // ---------------------------------------------------------------------------

  Widget _buildCustomerSummaryBanner() {
    final cust = _selectedCustomer!;
    final prevReturns = ReturnService.instance.countPreviousReturns();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: DashboardColors.glassCard(
        borderColor: const Color(0x3300D4FF),
        fillColor: const Color(0x1F00D4FF),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: DashboardColors.neonBlue.withValues(alpha: 0.2),
            child: const Icon(Icons.person_outline_rounded, color: DashboardColors.neonBlue, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      cust['name'] ?? 'Walk-in Customer',
                      style: DashboardTypography.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0x3310B981),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0x6610B981)),
                      ),
                      child: Text(
                        'ID: ${cust['id'] ?? 'N/A'}',
                        style: DashboardTypography.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: DashboardColors.neonGreen,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Phone: ${cust['phone']}  •  Total Invoices Found: ${_purchasedProducts.map((p) => p.invoiceNumber).toSet().length}',
                  style: DashboardTypography.inter(
                    fontSize: 12.5,
                    color: DashboardColors.textLight,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0x26000000),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: DashboardColors.glassBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Purchased Items',
                  style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted),
                ),
                Text(
                  '${_purchasedProducts.length} Items',
                  style: DashboardTypography.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: DashboardColors.neonBlue,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PRODUCTS SECTION
  // ---------------------------------------------------------------------------

  Widget _buildProductsSection() {
    if (_purchasedProducts.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(36),
        decoration: DashboardColors.glassCard(),
        child: Column(
          children: [
            const Icon(Icons.remove_shopping_cart_rounded, size: 54, color: DashboardColors.textMuted),
            const SizedBox(height: 14),
            Text(
              'No Purchase Records Found For This Number',
              style: DashboardTypography.poppins(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Please check the mobile number or verify if the invoice was registered under a different phone number.',
              textAlign: TextAlign.center,
              style: DashboardTypography.inter(fontSize: 12.5, color: DashboardColors.textMuted),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_other_rounded, color: DashboardColors.neonGreen, size: 22),
                const SizedBox(width: 8),
                Text(
                  '2. PURCHASED PRODUCTS & WARRANTY ELIGIBILITY',
                  style: DashboardTypography.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: DashboardColors.neonGreen,
                  ),
                ),
              ],
            ),
            Text(
              'Showing ${_purchasedProducts.length} items',
              style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 900;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: isDesktop ? 2 : 1,
                mainAxisExtent: 290,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: _purchasedProducts.length,
              itemBuilder: (context, idx) {
                final item = _purchasedProducts[idx];
                return _buildProductCard(item);
              },
            );
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // PRODUCT CARD
  // ---------------------------------------------------------------------------

  Widget _buildProductCard(PurchasedProductItem item) {
    final warrantyColor = CustomerWarrantyStatus.getColor(item.calculatedWarrantyStatus);
    final warrantyIcon = CustomerWarrantyStatus.getIcon(item.calculatedWarrantyStatus);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: DashboardColors.glassCard(
        borderColor: warrantyColor.withValues(alpha: 0.4),
        glow: item.calculatedWarrantyStatus == CustomerWarrantyStatus.active,
        glowColor: DashboardColors.neonGreen,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Product name & Warranty badge
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.productName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DashboardTypography.poppins(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    if (item.brand.isNotEmpty || item.model.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${item.brand} ${item.model}'.trim(),
                        style: DashboardTypography.inter(
                          fontSize: 11.5,
                          color: DashboardColors.textLight,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: warrantyColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: warrantyColor.withValues(alpha: 0.6)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(warrantyIcon, color: warrantyColor, size: 14),
                    const SizedBox(width: 5),
                    Text(
                      item.calculatedWarrantyStatus,
                      style: DashboardTypography.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: warrantyColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),
          const Divider(height: 1, thickness: 1, color: Color(0x1AFFFFFF)),
          const SizedBox(height: 12),

          // Details grid
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildProductDetailRow('Invoice Number', item.invoiceNumber, Icons.receipt_long_rounded),
                _buildProductDetailRow('Purchase Date', _shortDateFormat.format(item.purchaseDate), Icons.event_rounded),
                _buildProductDetailRow(
                  'Serial / IMEI',
                  item.serialNumber.isNotEmpty ? item.serialNumber : 'Not Recorded',
                  Icons.qr_code_rounded,
                  highlight: item.serialNumber.isNotEmpty,
                ),
                _buildProductDetailRow(
                  'Warranty Term',
                  item.warrantyExpiryDate != null
                      ? '${item.warrantyPeriod} (Expires ${_shortDateFormat.format(item.warrantyExpiryDate!)})'
                      : item.warrantyPeriod,
                  Icons.shield_rounded,
                  valueColor: warrantyColor,
                ),
                if (item.originalVendorName != null && item.originalVendorName!.isNotEmpty)
                  _buildProductDetailRow('Original Vendor', item.originalVendorName!, Icons.store_rounded),
                if (item.previousReturnCount > 0)
                  _buildProductDetailRow(
                    'Previous Returns',
                    '${item.previousReturnCount} times',
                    Icons.history_rounded,
                    valueColor: DashboardColors.neonOrange,
                  ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Action buttons: View Details, Check Warranty, Register Return
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: DashboardColors.textLight,
                    side: const BorderSide(color: Color(0x33FFFFFF)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: () => _showProductDetailsDialog(item),
                  child: Text(
                    'View Details',
                    style: DashboardTypography.inter(fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: warrantyColor,
                    side: BorderSide(color: warrantyColor.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: () => _showWarrantyCheckDialog(item),
                  child: Text(
                    'Check Warranty',
                    style: DashboardTypography.inter(fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: DashboardColors.primaryBlue,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: () => _showRegisterReturnDialog(item),
                  child: Text(
                    'Register Return',
                    style: DashboardTypography.poppins(fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProductDetailRow(
    String label,
    String value,
    IconData icon, {
    Color? valueColor,
    bool highlight = false,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: DashboardColors.textMuted),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: DashboardTypography.inter(fontSize: 11.5, color: DashboardColors.textMuted),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DashboardTypography.inter(
              fontSize: 11.5,
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
              color: valueColor ?? (highlight ? DashboardColors.neonBlue : Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // INITIAL GUIDE
  // ---------------------------------------------------------------------------

  Widget _buildSearchGuide() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(40),
      decoration: DashboardColors.glassCard(),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: DashboardColors.neonBlue.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(color: DashboardColors.neonBlue.withValues(alpha: 0.3)),
            ),
            child: const Icon(Icons.manage_search_rounded, size: 36, color: DashboardColors.neonBlue),
          ),
          const SizedBox(height: 18),
          Text(
            'Ready to Process a Customer Return',
            style: DashboardTypography.poppins(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 550),
            child: Text(
              'Enter the customer\'s mobile number above to retrieve all previous sales, verify the original invoice and serial numbers, calculate real-time warranty eligibility, and seamlessly identify the original vendor.',
              textAlign: TextAlign.center,
              style: DashboardTypography.inter(
                fontSize: 13,
                color: DashboardColors.textMuted,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DIALOG 1: VIEW FULL PRODUCT DETAILS
  // ---------------------------------------------------------------------------

  void _showProductDetailsDialog(PurchasedProductItem item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0x33FFFFFF)),
        ),
        title: Row(
          children: [
            const Icon(Icons.info_outline_rounded, color: DashboardColors.neonBlue),
            const SizedBox(width: 10),
            Text(
              'Purchased Product Details',
              style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildModalRow('Product Name', item.productName),
              _buildModalRow('Brand / Model', '${item.brand} ${item.model}'.trim()),
              _buildModalRow('Original Invoice #', item.invoiceNumber),
              _buildModalRow('Purchase Date', _dateFormat.format(item.purchaseDate)),
              _buildModalRow('Serial Number / IMEI', item.serialNumber.isNotEmpty ? item.serialNumber : 'Not Specified'),
              _buildModalRow('Sale Price', '₹${item.price.toStringAsFixed(2)}'),
              _buildModalRow('Quantity', '${item.quantity}'),
              _buildModalRow('Warranty Term', item.warrantyPeriod),
              _buildModalRow('Warranty Expiry Date', item.warrantyExpiryDate != null ? _dateFormat.format(item.warrantyExpiryDate!) : 'No Expiry'),
              _buildModalRow('Calculated Status', item.calculatedWarrantyStatus),
              _buildModalRow('Original Vendor', item.originalVendorName ?? 'Not Linked In Purchase Records'),
              _buildModalRow('Vendor Phone', item.originalVendorPhone ?? 'N/A'),
              _buildModalRow('Previous Return Count', '${item.previousReturnCount} times'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Close', style: DashboardTypography.inter(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DashboardColors.primaryBlue),
            onPressed: () {
              Navigator.pop(ctx);
              _showRegisterReturnDialog(item);
            },
            child: Text('Proceed to Return', style: DashboardTypography.inter(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DIALOG 2: CHECK WARRANTY
  // ---------------------------------------------------------------------------

  void _showWarrantyCheckDialog(PurchasedProductItem item) {
    final status = item.calculatedWarrantyStatus;
    final color = CustomerWarrantyStatus.getColor(status);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: color.withValues(alpha: 0.5)),
        ),
        title: Row(
          children: [
            Icon(CustomerWarrantyStatus.getIcon(status), color: color),
            const SizedBox(width: 10),
            Text(
              'Customer Warranty Evaluation',
              style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    Icon(CustomerWarrantyStatus.getIcon(status), color: color, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            status,
                            style: DashboardTypography.poppins(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: color,
                            ),
                          ),
                          Text(
                            item.warrantyExpiryDate != null
                                ? 'Coverage ends on ${_dateFormat.format(item.warrantyExpiryDate!)}'
                                : 'No active warranty period specified on invoice',
                            style: DashboardTypography.inter(fontSize: 11.5, color: DashboardColors.textLight),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _buildModalRow('Product', item.productName),
              _buildModalRow('Invoice Number', item.invoiceNumber),
              _buildModalRow('Purchase Date', _shortDateFormat.format(item.purchaseDate)),
              _buildModalRow('Specified Warranty', item.warrantyPeriod),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x1AFFFFFF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Note: Customer warranty terms are evaluated strictly from the customer purchase invoice. Vendor claim terms are evaluated separately and will be tracked after vendor handover.',
                  style: DashboardTypography.inter(fontSize: 11, color: DashboardColors.textMuted, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Done', style: DashboardTypography.inter(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DIALOG 3: REGISTER RETURN FORM (STAGE 4 & 5)
  // ---------------------------------------------------------------------------

  void _showRegisterReturnDialog(PurchasedProductItem item) {
    final complaintCtrl = TextEditingController();
    final conditionCtrl = TextEditingController(text: 'Normal wear and tear');
    final accessoriesCtrl = TextEditingController(text: 'Product only');
    final notesCtrl = TextEditingController();
    final photoNoteCtrl = TextEditingController();
    final vendorNameCtrl = TextEditingController(text: item.originalVendorName ?? '');
    final vendorPhoneCtrl = TextEditingController(text: item.originalVendorPhone ?? '');
    final vendorRefCtrl = TextEditingController();

    String selectedReason = ReturnReason.productNotWorking;
    String selectedWarrantyStatus = item.calculatedWarrantyStatus;
    DateTime returnDate = DateTime.now();
    bool submitting = false;

    final auth = context.read<AuthController>();
    String assignedStaff = auth.name.isNotEmpty ? auth.name : 'Staff';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0x3300D4FF)),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: DashboardColors.activePillGradient,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.assignment_return_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Register Customer Return',
                      style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      'Links return to Invoice ${item.invoiceNumber} without altering original sales',
                      style: DashboardTypography.inter(fontSize: 11.5, color: DashboardColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Auto-populated Summary Card
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0x1A1B2A55),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0x24FFFFFF)),
                    ),
                    child: Column(
                      children: [
                        _buildAutoPopulatedField('Customer', '${item.customerName} (${item.customerPhone})'),
                        _buildAutoPopulatedField('Product', '${item.productName} (IMEI: ${item.serialNumber.isNotEmpty ? item.serialNumber : "N/A"})'),
                        _buildAutoPopulatedField('Invoice & Date', '${item.invoiceNumber} • ${_shortDateFormat.format(item.purchaseDate)}'),
                        _buildAutoPopulatedField('Warranty', '${item.warrantyPeriod} • $selectedWarrantyStatus'),
                        _buildAutoPopulatedField('Original Vendor', item.originalVendorName ?? 'Not in records (manual entry below)'),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Return Reason Dropdown
                  Text(
                    'Return Reason *',
                    style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600, color: DashboardColors.textLight),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0x26000000),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x33FFFFFF)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        dropdownColor: const Color(0xFF1E293B),
                        value: selectedReason,
                        items: ReturnReason.all.map((r) {
                          return DropdownMenuItem(
                            value: r,
                            child: Text(r, style: DashboardTypography.inter(color: Colors.white, fontSize: 13.5)),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) setD(() => selectedReason = val);
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Customer Complaint
                  Text(
                    'Customer Complaint *',
                    style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600, color: DashboardColors.textLight),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: complaintCtrl,
                    maxLines: 2,
                    style: DashboardTypography.inter(color: Colors.white, fontSize: 13),
                    decoration: _buildInputDecoration('Describe problem reported by customer...'),
                  ),

                  const SizedBox(height: 14),

                  // Product Condition & Accessories
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Product Condition',
                              style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600, color: DashboardColors.textLight),
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: conditionCtrl,
                              style: DashboardTypography.inter(color: Colors.white, fontSize: 13),
                              decoration: _buildInputDecoration('e.g. Scratched, Good, etc.'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Accessories Received',
                              style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600, color: DashboardColors.textLight),
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: accessoriesCtrl,
                              style: DashboardTypography.inter(color: Colors.white, fontSize: 13),
                              decoration: _buildInputDecoration('e.g. Box, Charger, Bill, None'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Original Vendor Information
                  Text(
                    'Original Vendor Information',
                    style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600, color: DashboardColors.neonBlue),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: vendorNameCtrl,
                          style: DashboardTypography.inter(color: Colors.white, fontSize: 13),
                          decoration: _buildInputDecoration('Vendor Name (Auto/Manual)'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: vendorPhoneCtrl,
                          keyboardType: TextInputType.phone,
                          style: DashboardTypography.inter(color: Colors.white, fontSize: 13),
                          decoration: _buildInputDecoration('Vendor Phone'),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Internal Notes
                  Text(
                    'Internal Notes',
                    style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.w600, color: DashboardColors.textLight),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: notesCtrl,
                    style: DashboardTypography.inter(color: Colors.white, fontSize: 13),
                    decoration: _buildInputDecoration('Optional staff internal notes...'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(ctx),
              child: Text('Cancel', style: DashboardTypography.inter(color: Colors.white70)),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: DashboardColors.primaryBlue,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              onPressed: submitting
                  ? null
                  : () async {
                      if (complaintCtrl.text.trim().isEmpty) {
                        toast(context, 'Please enter the customer complaint', error: true);
                        return;
                      }

                      setD(() => submitting = true);

                      try {
                        final ret = await ReturnService.instance.registerReturn(
                          customerName: item.customerName,
                          customerPhone: item.customerPhone,
                          customerKey: item.customerKey,
                          customerId: item.customerKey?.toString(),
                          originalInvoiceNumber: item.invoiceNumber,
                          originalSaleKey: item.saleKey,
                          originalItemKey: item.itemKey,
                          originalPurchaseDate: item.purchaseDate,
                          productName: item.productName,
                          productBrand: item.brand,
                          productModel: item.model,
                          serialNumber: item.serialNumber,
                          salePrice: item.price,
                          customerWarrantyPeriod: item.warrantyPeriod,
                          customerWarrantyExpiryDate: item.warrantyExpiryDate,
                          customerWarrantyStatus: item.calculatedWarrantyStatus,
                          originalVendorKey: item.originalVendorKey,
                          originalVendorName: vendorNameCtrl.text.trim().isNotEmpty
                              ? vendorNameCtrl.text.trim()
                              : item.originalVendorName,
                          originalVendorPhone: vendorPhoneCtrl.text.trim().isNotEmpty
                              ? vendorPhoneCtrl.text.trim()
                              : item.originalVendorPhone,
                          returnReason: selectedReason,
                          customerComplaint: complaintCtrl.text.trim(),
                          productCondition: conditionCtrl.text.trim(),
                          accessoriesReceived: accessoriesCtrl.text.trim(),
                          assignedStaffId: auth.uid,
                          assignedStaffName: assignedStaff,
                          internalNotes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                          actorId: auth.uid,
                          actorName: assignedStaff,
                          actorRole: auth.isOwner ? 'Owner' : 'Staff',
                        );

                        if (ctx.mounted) Navigator.pop(ctx);
                        if (!mounted) return;
                        toast(context, 'Return Registered: ${ret.returnId}');
                        // Navigate directly to Case Details
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReturnDetailsScreen(returnKey: ret.key),
                          ),
                        );
                      } catch (e) {
                        setD(() => submitting = false);
                        if (mounted) {
                          toast(context, 'Failed to register return: $e', error: true);
                        }
                      }
                    },
              icon: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check_circle_rounded, size: 18),
              label: Text(
                'Confirm & Register',
                style: DashboardTypography.poppins(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutoPopulatedField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              '$label:',
              style: DashboardTypography.inter(fontSize: 11.5, color: DashboardColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: DashboardTypography.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _buildInputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: DashboardTypography.inter(color: DashboardColors.textMuted, fontSize: 12),
      filled: true,
      fillColor: const Color(0x26000000),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0x33FFFFFF)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0x33FFFFFF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: DashboardColors.neonBlue),
      ),
    );
  }

  Widget _buildModalRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              '$label:',
              style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: DashboardTypography.inter(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
