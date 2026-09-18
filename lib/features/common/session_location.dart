import 'package:flutter/cupertino.dart';

/// The one glyph for where a session's repository lives: a globe for a remote
/// (SSH) repository, a folder for one on this Mac. The tab chip, the status
/// bar and the sidebar Location row all take it from here, so the three agree
/// (MADR 0052, amendment 0052.1).
IconData sessionLocationIcon({required bool isLocal}) =>
    isLocal ? CupertinoIcons.folder : CupertinoIcons.globe;
