import 'package:flutter/material.dart';

import '../app_colors.dart';
class PlaceholderScreen extends StatelessWidget {
  final String title;
  final IconData icon;
  final String subtitle;

  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle = 'Coming soon!',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 72, color: Colors.white12),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(subtitle,
              style: TextStyle(color: AppColors.t54, fontSize: 14)),
        ]),
      ),
    );
  }
}
