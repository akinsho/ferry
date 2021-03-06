import 'dart:async';
import 'package:meta/meta.dart';
import 'package:hive/hive.dart';
import 'package:built_value/serializer.dart';
import 'package:gql/ast.dart';
import 'package:rxdart/rxdart.dart';
import 'package:normalize/utils.dart';
import 'package:ferry_exec/ferry_exec.dart';
import 'package:ferry_cache/ferry_cache.dart';
import 'package:gql_link/gql_link.dart';

export 'package:hive/hive.dart';
export 'package:ferry_cache/ferry_cache.dart';

typedef LinkExceptionHandler<TData, TVars> = void Function(
  OperationResponse<TData, TVars> response,
  EventSink<OperationResponse<TData, TVars>> sink,
);

/// Caches mutations in a `hive` box when offline and re-runs them when
/// re-connected.
///
/// This link must be between a `RequestControllerTypedLink` and the
/// terminating link.
class OfflineMutationTypedLink extends TypedLink {
  /// A [hive] box where the mutation will be stored.
  final Box<Map<String, dynamic>> mutationQueueBox;

  /// The [Serializers] object generated by ferry's codegen.
  final Serializers serializers;

  final Cache cache;
  final StreamController<OperationRequest> requestController;

  /// A callback used to customize behavior when a mutation execution results in a [LinkException].
  final LinkExceptionHandler linkExceptionHandler;

  bool _connected = false;

  bool get connected => _connected;

  set connected(bool isConnected) {
    _connected = isConnected;
    if (isConnected) _handleOnConnect();
  }

  /// [OfflineMutationPlugin] can be used to maintain an Offline Mutation queue.
  ///
  /// This plugin is intended to be an example for how offline mutations can be
  /// handled with ferry but doesn't address all edge cases.
  ///
  /// Some limitations include:
  /// 1. If the client shuts down during an inflight mutation (i.e. after a
  /// mutation has been sent to the server but before a response has been received),
  /// the mutation is assumed to have completed succesfully.
  /// 2. When coming back online, all queued mutations are executed immediately
  /// in parallel, not serially. This could lead to unexpected behavior.
  OfflineMutationTypedLink({
    @required this.mutationQueueBox,
    @required this.serializers,
    @required this.cache,
    @required this.requestController,
    this.linkExceptionHandler,
  });

  void _handleOnConnect() => mutationQueueBox.values.forEach((json) {
        final OperationRequest req = serializers.deserialize(json);

        // Run unexecuted mutations
        requestController.add(req);
      });

  bool _isMutation(OperationRequest req) =>
      getOperationDefinition(
        req.operation.document,
        req.operation.operationName,
      ).type ==
      OperationType.mutation;

  @override
  Stream<OperationResponse<TData, TVars>> request<TData, TVars>(
    OperationRequest<TData, TVars> request, [
    NextTypedLink<TData, TVars> forward,
  ]) =>
      _handleRequest(request, forward).transform(_responseTransformer());

  Stream<OperationResponse<TData, TVars>> _handleRequest<TData, TVars>(
    OperationRequest<TData, TVars> request, [
    NextTypedLink<TData, TVars> forward,
  ]) {
    // Forward along any operations that aren't Mutations
    if (_isMutation(request) == false) return forward(request);

    // If the client is online, execute the mutation
    if (connected) return forward(request);

    // Save mutation to the queue
    mutationQueueBox.add(serializers.serialize(request));

    // Add an optimistic patch to the cache, if necessary
    if (request.optimisticResponse != null) {
      cache.writeQuery(
        request,
        request.optimisticResponse,
        optimisticRequest: request,
      );
    }

    /// Don't forward
    return NeverStream();
  }

  StreamTransformer<OperationResponse<TData, TVars>,
          OperationResponse<TData, TVars>>
      _responseTransformer<TData, TVars>() => StreamTransformer.fromHandlers(
            handleData: (res, sink) {
              // Forward along any responses for operations that aren't Mutations
              if (_isMutation(res.operationRequest) == false) {
                return sink.add(res);
              }

              if (res.linkException is ServerException &&
                  linkExceptionHandler != null) {
                return linkExceptionHandler(res, sink);
              }

              // Forward response and remove mutation from queue
              sink.add(res);
              final queueKey = mutationQueueBox.values.toList().indexWhere(
                    (serialized) =>
                        res.operationRequest ==
                        serializers.deserialize(serialized),
                  );
              if (queueKey != -1) mutationQueueBox.delete(queueKey);
            },
          );
}
