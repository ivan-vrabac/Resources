import 'package:flutter/material.dart';

/// Popups that can't stack or over-close (owner 2026-10-23: double taps opened two popups, and
/// a second close after a network wait popped the screen underneath, leaving a black screen).

/// The screen of [context] is covered by another popup (opened by an earlier tap).
bool _covered(BuildContext context) {
  if (!context.mounted) return true;
  final route = ModalRoute.of(context);
  return route != null && route.isActive && !route.isCurrent;
}

/// [showDialog] that does nothing (returns null) while a popup already covers the screen.
Future<T?> showAppDialog<T>({required BuildContext context, required WidgetBuilder builder}) =>
    _covered(context) ? Future<T?>.value() : showDialog<T>(context: context, builder: builder);

/// [showModalBottomSheet] that does nothing (returns null) while a popup already covers the screen.
Future<T?> showAppSheet<T>({required BuildContext context, required WidgetBuilder builder,
    bool isScrollControlled = false}) =>
    _covered(context)
        ? Future<T?>.value()
        : showModalBottomSheet<T>(context: context, builder: builder, isScrollControlled: isScrollControlled);

Route<dynamic>? _uncoveredRoute;
DateTime _uncoveredAt = DateTime(2000);

/// Closes the popup/page of [context] once. A second call (double tap, late network reply) is
/// ignored instead of closing the screen underneath.
void popIfCurrent<T extends Object?>(BuildContext context, [T? result]) {
  if (!context.mounted) return;
  final route = ModalRoute.of(context);
  if (route == null) {
    Navigator.of(context).pop(result);
    return;
  }
  if (!route.isActive) return;                         // already closed
  if (route.isCurrent) {
    // this screen was just uncovered by closing a popup on its behalf: that close was the one
    if (identical(route, _uncoveredRoute) &&
        DateTime.now().difference(_uncoveredAt) < const Duration(milliseconds: 1500)) {
      _uncoveredRoute = null;
      return;
    }
    Navigator.of(context).pop(result);
    return;
  }
  // asked with the context of the screen under a popup: close that popup, once
  _uncoveredRoute = route;
  _uncoveredAt = DateTime.now();
  Navigator.of(context).pop(result);
}
