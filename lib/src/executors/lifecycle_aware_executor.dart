import 'package:executor_lib/executor_lib.dart';

abstract class LifecycleAwareExecutor implements Executor {
  bool get isSuspended;

  void suspend();

  void resume();
}
