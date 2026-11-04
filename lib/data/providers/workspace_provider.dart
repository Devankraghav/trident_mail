import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WorkspaceProvider extends ChangeNotifier {
  int _activeSlotIndex = 0;
  bool _isDarkMode = true;

  int get activeSlotIndex => _activeSlotIndex;
  bool get isDarkMode => _isDarkMode;

  WorkspaceProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _activeSlotIndex = prefs.getInt('active_slot_index') ?? 0;
    _isDarkMode = prefs.getBool('is_dark_mode') ?? true;
    notifyListeners();
  }

  Future<void> setActiveSlotIndex(int index) async {
    _activeSlotIndex = index;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('active_slot_index', index);
  }

  Future<void> toggleDarkMode() async {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_dark_mode', _isDarkMode);
  }
}
