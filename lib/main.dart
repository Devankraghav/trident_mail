import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_windows/webview_windows.dart';

import 'core/theme.dart';
import 'data/models/account_config.dart';
import 'data/providers/workspace_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => WorkspaceProvider(),
      child: const TridentMailApp(),
    ),
  );
}

class TridentMailApp extends StatelessWidget {
  const TridentMailApp({super.key});

  @override
  Widget build(BuildContext context) {
    final workspace = context.watch<WorkspaceProvider>();
    return MaterialApp(
      title: 'Trident Mail',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: workspace.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: const TridentMailWorkspace(),
    );
  }
}

/// Represents the session state and WebviewController for an account slot.
class SlotSession {
  final int index;
  final AccountSlotData slotData;
  WebviewController? controller;
  bool isInitialized = false;
  bool isLoading = false;
  String currentUrl = '';
  String currentTitle = '';
  bool canGoBack = false;
  bool canGoForward = false;
  String? error;

  SlotSession({required this.index, required this.slotData});

  String get label => 'Connect ${index + 1}';

  bool get isConnected => slotData.isConnected;
}

class TridentMailWorkspace extends StatefulWidget {
  const TridentMailWorkspace({super.key});

  @override
  State<TridentMailWorkspace> createState() => _TridentMailWorkspaceState();
}

class _TridentMailWorkspaceState extends State<TridentMailWorkspace> {
  static const String defaultDesktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.0.0';

  late final List<SlotSession> _slots;
  int _activeSlotIndex = 0;
  bool _isAppLoading = true;
  bool _envInitialized = false;

  @override
  void initState() {
    super.initState();
    _slots = [
      SlotSession(index: 0, slotData: AccountSlotData(index: 0)),
      SlotSession(index: 1, slotData: AccountSlotData(index: 1)),
      SlotSession(index: 2, slotData: AccountSlotData(index: 2)),
    ];
    _initializeWorkspace();
  }

  Future<void> _initializeWorkspace() async {
    final prefs = await SharedPreferences.getInstance();
    _activeSlotIndex = prefs.getInt('active_slot_index') ?? 0;
    if (_activeSlotIndex < 0 || _activeSlotIndex > 2) {
      _activeSlotIndex = 0;
    }

    // Load saved account configurations
    for (int i = 0; i < 3; i++) {
      final String? email = prefs.getString('slot_${i}_email');
      final bool isConnected = prefs.getBool('slot_${i}_connected') ?? false;
      if (email != null && email.isNotEmpty) {
        _slots[i].slotData.email = email;
        _slots[i].slotData.isConnected = isConnected;
      }
    }

    // Explicitly initialize the underlying WebView2 environment once for the app
    if (!_envInitialized) {
      try {
        await WebviewController.initializeEnvironment().timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('WebView2 environment initialization timed out');
          },
        );
        _envInitialized = true;
      } catch (e) {
        debugPrint('WebView2 environment init info: $e');
        _envInitialized = true;
      }
    }

    if (mounted) {
      setState(() {
        _isAppLoading = false;
      });
    }

    // Initialize active slot controller first so user sees Gmail immediately
    await _initializeSlotController(_activeSlotIndex);

    // Sequentially initialize remaining slots in background for instant switching
    for (int i = 0; i < 3; i++) {
      if (i != _activeSlotIndex && mounted) {
        await _initializeSlotController(i);
      }
    }
  }

  String _getTargetUrlForSlot(int index) {
    final slot = _slots[index];
    if (index == 0) {
      return 'https://mail.google.com/mail/u/0/';
    } else {
      if (slot.isConnected || (slot.slotData.email != null && slot.slotData.email!.isNotEmpty)) {
        return 'https://mail.google.com/mail/u/$index/';
      } else {
        return 'https://accounts.google.com/AddSession?hl=en&continue=https://mail.google.com/mail/u/$index/';
      }
    }
  }

  Future<void> _initializeSlotController(int index) async {
    final slot = _slots[index];
    if (slot.isInitialized && slot.controller != null) return;

    if (mounted) {
      setState(() {
        slot.isLoading = true;
        slot.error = null;
      });
    }

    try {
      final controller = WebviewController();

      // Initialize controller with a 12-second timeout
      await controller.initialize().timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          throw TimeoutException('WebView2 initialization timed out for Slot ${index + 1}');
        },
      );

      await controller.setUserAgent(defaultDesktopUA);

      slot.controller = controller;

      // Attach stream listeners BEFORE loading URL to prevent missing events
      controller.url.listen((url) {
        if (!mounted) return;
        _onUrlChanged(index, url);
      });

      controller.title.listen((title) {
        if (!mounted) return;
        _onTitleChanged(index, title);
      });

      controller.historyChanged.listen((history) {
        if (!mounted) return;
        setState(() {
          slot.canGoBack = history.canGoBack;
          slot.canGoForward = history.canGoForward;
        });
      });

      controller.loadingState.listen((state) {
        if (!mounted) return;
        setState(() {
          slot.isLoading = (state == LoadingState.loading);
        });
      });

      slot.isInitialized = true;

      final targetUrl = _getTargetUrlForSlot(index);
      slot.currentUrl = targetUrl;

      await controller.loadUrl(targetUrl).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          debugPrint('Slot $index loadUrl timed out, proceeding with Webview rendering');
        },
      );
    } catch (err) {
      debugPrint('Error initializing slot $index: $err');
      if (mounted) {
        setState(() {
          slot.isInitialized = false;
          slot.error = 'Unable to initialize Slot ${index + 1}: $err';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          slot.isLoading = false;
        });
      }
    }
  }

  void _onUrlChanged(int index, String url) {
    final slot = _slots[index];
    slot.currentUrl = url;

    bool isGmailWorkspace = url.contains('mail.google.com');

    if (isGmailWorkspace) {
      if (!slot.slotData.isConnected) {
        slot.slotData.isConnected = true;
        _saveSlotState(index);
      }
    }

    if (mounted) {
      setState(() {});
    }
  }

  void _onTitleChanged(int index, String title) {
    final slot = _slots[index];
    slot.currentTitle = title;

    // Extract email from Gmail window title e.g. "Inbox (5) - user@gmail.com - Gmail"
    final emailRegex = RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}');
    final match = emailRegex.firstMatch(title);
    if (match != null) {
      final extractedEmail = match.group(0);
      if (extractedEmail != null && extractedEmail.isNotEmpty) {
        if (slot.slotData.email != extractedEmail || !slot.slotData.isConnected) {
          slot.slotData.email = extractedEmail;
          slot.slotData.isConnected = true;
          _saveSlotState(index);
        }
      }
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _saveSlotState(int index) async {
    final prefs = await SharedPreferences.getInstance();
    final slot = _slots[index];
    if (slot.slotData.email != null) {
      await prefs.setString('slot_${index}_email', slot.slotData.email!);
    } else {
      await prefs.remove('slot_${index}_email');
    }
    await prefs.setBool('slot_${index}_connected', slot.slotData.isConnected);
  }

  Future<void> _selectSlot(int index) async {
    if (_activeSlotIndex == index) return;

    setState(() {
      _activeSlotIndex = index;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('active_slot_index', index);

    // Initialize controller for target slot if not ready
    if (!_slots[index].isInitialized) {
      await _initializeSlotController(index);
    }
  }

  Future<void> _retrySlot(int index) async {
    final slot = _slots[index];
    slot.controller?.dispose();
    slot.controller = null;
    slot.isInitialized = false;
    slot.error = null;
    await _initializeSlotController(index);
  }

  Future<void> _disconnectSlot(int index) async {
    final slot = _slots[index];
    slot.slotData.email = null;
    slot.slotData.isConnected = false;
    await _saveSlotState(index);

    if (slot.controller != null && slot.isInitialized) {
      final logoutUrl =
          'https://accounts.google.com/Logout?continue=${Uri.encodeComponent('https://mail.google.com/mail/u/$index/')}';
      slot.currentUrl = logoutUrl;
      await slot.controller!.loadUrl(logoutUrl);
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _reloadActiveSlot() async {
    final activeSlot = _slots[_activeSlotIndex];
    if (activeSlot.controller != null && activeSlot.isInitialized) {
      await activeSlot.controller!.reload();
    }
  }

  Future<void> _goBackActiveSlot() async {
    final activeSlot = _slots[_activeSlotIndex];
    if (activeSlot.controller != null && activeSlot.isInitialized && activeSlot.canGoBack) {
      await activeSlot.controller!.goBack();
    }
  }

  Future<void> _goForwardActiveSlot() async {
    final activeSlot = _slots[_activeSlotIndex];
    if (activeSlot.controller != null && activeSlot.isInitialized && activeSlot.canGoForward) {
      await activeSlot.controller!.goForward();
    }
  }

  Future<void> _goHomeActiveSlot() async {
    final activeSlot = _slots[_activeSlotIndex];
    if (activeSlot.controller != null && activeSlot.isInitialized) {
      final targetUrl = _getTargetUrlForSlot(_activeSlotIndex);
      await activeSlot.controller!.loadUrl(targetUrl);
    }
  }

  @override
  void dispose() {
    for (var slot in _slots) {
      slot.controller?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workspace = context.watch<WorkspaceProvider>();
    final isDark = workspace.isDarkMode;
    final activeSlot = _slots[_activeSlotIndex];

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        leadingWidth: 170,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF4F46E5).withValues(alpha: 0.3),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.mark_email_unread_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Trident Mail',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        letterSpacing: -0.2,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Gmail Workspace',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        color: isDark ? Colors.grey[400] : Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          // Preserve Connect 1, Connect 2, and Connect 3 buttons
          Row(
            children: List.generate(3, (index) {
              final slot = _slots[index];
              final isSelected = _activeSlotIndex == index;

              return Padding(
                padding: const EdgeInsets.only(right: 10.0),
                child: _buildConnectButton(
                  index: index,
                  slot: slot,
                  isSelected: isSelected,
                  isDark: isDark,
                ),
              );
            }),
          ),
          const VerticalDivider(width: 16, indent: 16, endIndent: 16),
          // Dark Mode Toggle
          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              size: 20,
            ),
            tooltip: isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
            onPressed: () => workspace.toggleDarkMode(),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          // Navigation Toolbar Ribbon
          Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.grey[100],
              border: Border(
                bottom: BorderSide(
                  color: isDark ? const Color(0xFF334155) : Colors.grey[300]!,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  tooltip: 'Back',
                  onPressed: activeSlot.canGoBack ? _goBackActiveSlot : null,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  tooltip: 'Forward',
                  onPressed: activeSlot.canGoForward ? _goForwardActiveSlot : null,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  tooltip: 'Reload Page',
                  onPressed: _reloadActiveSlot,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.home_outlined, size: 18),
                  tooltip: 'Go to Inbox',
                  onPressed: _goHomeActiveSlot,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F172A) : Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isDark ? const Color(0xFF334155) : Colors.grey[300]!,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          activeSlot.isConnected
                              ? Icons.lock_outline_rounded
                              : Icons.security_rounded,
                          size: 14,
                          color: activeSlot.isConnected ? const Color(0xFF10B981) : Colors.amber,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            activeSlot.currentTitle.isNotEmpty
                                ? activeSlot.currentTitle
                                : (activeSlot.slotData.email ??
                                    'Slot ${activeSlot.index + 1} Workspace'),
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.grey[300] : Colors.grey[800],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (activeSlot.isConnected)
                  IconButton(
                    icon: const Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent),
                    tooltip: 'Disconnect Account Slot ${activeSlot.index + 1}',
                    onPressed: () => _disconnectSlot(_activeSlotIndex),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
              ],
            ),
          ),

          // Active Webview Progress Line
          if (activeSlot.isLoading)
            const PreferredSize(
              preferredSize: Size.fromHeight(2),
              child: LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
              ),
            ),

          // Main Content Workspace (Fills remaining height and width with Gmail WebView)
          Expanded(
            child: _isAppLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF6366F1)),
                  )
                : IndexedStack(
                    index: _activeSlotIndex,
                    children: List.generate(3, (index) {
                      final slot = _slots[index];
                      if (slot.error != null) {
                        return _buildSlotErrorView(index, slot.error!, isDark);
                      }
                      if (!slot.isInitialized || slot.controller == null) {
                        return _buildSlotLoadingView(index, isDark);
                      }
                      return Webview(slot.controller!);
                    }),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectButton({
    required int index,
    required SlotSession slot,
    required bool isSelected,
    required bool isDark,
  }) {
    final labelText = slot.slotData.displayLabel;
    final isConnected = slot.isConnected;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _selectSlot(index),
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? (isDark
                    ? const Color(0xFF4F46E5).withValues(alpha: 0.25)
                    : const Color(0xFF4F46E5).withValues(alpha: 0.12))
                : (isDark ? const Color(0xFF1E293B) : Colors.grey[100]),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF6366F1)
                  : (isDark ? const Color(0xFF334155) : Colors.grey[300]!),
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Status Indicator Dot / Icon
              if (slot.isLoading && isSelected)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
                  ),
                )
              else
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isConnected
                        ? const Color(0xFF10B981)
                        : (isDark ? Colors.grey[600] : Colors.grey[400]),
                  ),
                ),
              const SizedBox(width: 8),
              Text(
                labelText,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? (isDark ? Colors.white : const Color(0xFF4F46E5))
                      : (isDark ? Colors.grey[300] : Colors.grey[700]),
                ),
              ),
              if (isConnected) ...[
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: Icon(
                    Icons.more_vert_rounded,
                    size: 14,
                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                  ),
                  tooltip: 'Slot Options',
                  onSelected: (value) {
                    if (value == 'disconnect') {
                      _disconnectSlot(index);
                    } else if (value == 'reload') {
                      if (_activeSlotIndex == index) {
                        _reloadActiveSlot();
                      }
                    } else if (value == 'home') {
                      if (_activeSlotIndex == index) {
                        _goHomeActiveSlot();
                      }
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'reload',
                      child: Row(
                        children: [
                          const Icon(Icons.refresh_rounded, size: 16),
                          const SizedBox(width: 8),
                          Text('Refresh Slot ${index + 1}',
                              style: GoogleFonts.poppins(fontSize: 12)),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'home',
                      child: Row(
                        children: [
                          const Icon(Icons.home_outlined, size: 16),
                          const SizedBox(width: 8),
                          Text('Go to Inbox', style: GoogleFonts.poppins(fontSize: 12)),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'disconnect',
                      child: Row(
                        children: [
                          const Icon(Icons.logout_rounded,
                              size: 16, color: Colors.redAccent),
                          const SizedBox(width: 8),
                          Text('Disconnect Slot ${index + 1}',
                              style: GoogleFonts.poppins(
                                  fontSize: 12, color: Colors.redAccent)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlotLoadingView(int index, bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(0xFF6366F1)),
          const SizedBox(height: 20),
          Text(
            'Initializing Workspace Slot ${index + 1}...',
            style: GoogleFonts.poppins(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.grey[300] : Colors.grey[700],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Loading Gmail interface directly underneath the app bar',
            style: GoogleFonts.poppins(
              fontSize: 12,
              color: isDark ? Colors.grey[500] : Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlotErrorView(int index, String error, bool isDark) {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 48, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(
                'Slot ${index + 1} Workspace Error',
                style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                error,
                style: GoogleFonts.poppins(color: Colors.grey[500], fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry Connection'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => _retrySlot(index),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
