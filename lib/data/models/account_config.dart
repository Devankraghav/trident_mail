class AccountSlotData {
  final int index;
  String? email;
  bool isConnected;
  String? customTitle;

  AccountSlotData({
    required this.index,
    this.email,
    this.isConnected = false,
    this.customTitle,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'email': email,
        'isConnected': isConnected,
        'customTitle': customTitle,
      };

  factory AccountSlotData.fromJson(Map<String, dynamic> json) => AccountSlotData(
        index: json['index'] as int? ?? 0,
        email: json['email'] as String?,
        isConnected: json['isConnected'] as bool? ?? false,
        customTitle: json['customTitle'] as String?,
      );

  String get defaultLabel => 'Connect ${index + 1}';

  String get displayLabel {
    if (email != null && email!.isNotEmpty) {
      return email!.contains('@') ? email!.split('@')[0] : email!;
    }
    return defaultLabel;
  }
}
