typedef CloseApprovalHandler = Future<bool> Function();

class CloseRequestGuard {
  CloseRequestGuard({this.approvalHandler});

  CloseApprovalHandler? approvalHandler;
  Future<bool>? _pending;

  Future<bool> request() {
    final pending = _pending;
    if (pending != null) return pending;
    final future = approvalHandler?.call() ?? Future.value(true);
    _pending = future;
    return future.whenComplete(() => _pending = null);
  }
}
