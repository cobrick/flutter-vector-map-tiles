import 'package:executor_lib/executor_lib.dart';

import 'killable_isolate_executor.dart';
import 'suspendable_executor.dart';

Executor newConcurrentExecutor({required int concurrency}) => concurrency > 0
    ? SuspendableExecutor(
        () => PoolExecutor(
          concurrency: concurrency,
          executorFactory: KillableIsolateExecutor.new,
        ),
      )
    : QueueExecutor();
