// Observable "open the Remote tab" request (ticket #66).
//
// The background module cannot navigate: it has no BuildContext and the shell
// owns the tab state. So a notification body tap only increments this counter;
// the shell watches it and performs the same `popUntil(root) + selectTab(Remote)`
// the mini-player already does. A monotonic counter (not a boolean) means two
// taps in a row each produce a change the shell can observe, and no reset is
// needed after handling.

import 'package:flutter_riverpod/flutter_riverpod.dart';

class OpenRemoteRequest extends Notifier<int> {
  @override
  int build() => 0;

  /// Signals the shell to open the Remote tab.
  void request() => state = state + 1;
}

final openRemoteRequestProvider =
    NotifierProvider<OpenRemoteRequest, int>(OpenRemoteRequest.new);
