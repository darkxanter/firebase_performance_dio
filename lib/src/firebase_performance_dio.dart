import 'package:dio/dio.dart';
import 'package:firebase_performance/firebase_performance.dart';

/// [Dio] client interceptor that hooks into request/response process
/// and calls Firebase Metric API in between. The request key is a unique generated key
/// stored in [RequestOptions.extra] field.
///
/// Additionally there is no good API of obtaining content length from interceptor
/// API so we're "approximating" the byte length based on headers & request data.
/// If you're not fine with this, you can provide your own implementation in the constructor
///
/// This interceptor might be counting parsing time into elapsed API call duration.
/// I am not fully aware of [Dio] internal architecture.
class DioFirebasePerformanceInterceptor extends Interceptor {
  DioFirebasePerformanceInterceptor({
    this.requestContentLengthMethod = defaultRequestContentLength,
    this.responseContentLengthMethod = defaultResponseContentLength,
  });

  /// key: requestKey unique key, value: ongoing metric
  final _map = <_UniqueKey, HttpMetric>{};
  final RequestContentLengthMethod requestContentLengthMethod;
  final ResponseContentLengthMethod responseContentLengthMethod;
  late final extraKey = runtimeType.toString();

  @override
  Future onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final metric = FirebasePerformance.instance.newHttpMetric(
        options.uri.normalized(),
        options.method.asHttpMethod()!,
      );
      final requestKey = _UniqueKey();
      options.extra[extraKey] = requestKey;
      _map[requestKey] = metric;
      final requestContentLength = requestContentLengthMethod(options);
      await metric.start();
      if (requestContentLength != null) {
        metric.requestPayloadSize = requestContentLength;
      }
    } catch (_) {}
    return super.onRequest(options, handler);
  }

  @override
  Future onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    await _stopMetric(response, response.requestOptions);
    return super.onResponse(response, handler);
  }

  @override
  Future onError(
    DioError err,
    ErrorInterceptorHandler handler,
  ) async {
    await _stopMetric(err.response, err.requestOptions);
    return super.onError(err, handler);
  }

  Future<void> _stopMetric(Response? response, RequestOptions options) async {
    try {
      final requestKey = options.extra[extraKey];
      if (requestKey is _UniqueKey) {
        final metric = _map[requestKey];
        metric?.setResponse(response, responseContentLengthMethod);
        await metric?.stop();
        _map.remove(requestKey);
      }
    } catch (_) {}
  }
}

typedef RequestContentLengthMethod = int? Function(RequestOptions options);
int? defaultRequestContentLength(RequestOptions options) {
  try {
    return options.headers.toString().length + options.data.toString().length;
  } catch (_) {
    return null;
  }
}

typedef ResponseContentLengthMethod = int? Function(Response options);
int? defaultResponseContentLength(Response response) {
  try {
    String? lengthHeader = response.headers[Headers.contentLengthHeader]?.first;
    int length = int.parse(lengthHeader ?? '-1');
    if (length <= 0) {
      int headers = response.headers.toString().length;
      length = headers + response.data.toString().length;
    }
    return length;
  } catch (_) {
    return null;
  }
}

extension _ResponseHttpMetric on HttpMetric {
  void setResponse(
    Response? value,
    ResponseContentLengthMethod responseContentLengthMethod,
  ) {
    if (value == null) {
      return;
    }
    final responseContentLength = responseContentLengthMethod(value);
    if (responseContentLength != null) {
      responsePayloadSize = responseContentLength;
    }
    final contentType = value.headers.value.call(Headers.contentTypeHeader);
    if (contentType != null) {
      responseContentType = contentType;
    }
    if (value.statusCode != null) {
      httpResponseCode = value.statusCode;
    }
  }
}

extension _UriHttpMethod on Uri {
  String normalized() {
    return "$scheme://$host$path";
  }
}

extension _StringHttpMethod on String {
  HttpMethod? asHttpMethod() {
    switch (toUpperCase()) {
      case 'POST':
        return HttpMethod.Post;
      case 'GET':
        return HttpMethod.Get;
      case 'DELETE':
        return HttpMethod.Delete;
      case 'PUT':
        return HttpMethod.Put;
      case 'PATCH':
        return HttpMethod.Patch;
      case 'OPTIONS':
        return HttpMethod.Options;
      default:
        return null;
    }
  }
}

class _UniqueKey {
  /// Creates a key that is equal only to itself.
  ///
  /// The key cannot be created with a const constructor because that implies
  /// that all instantiated keys would be the same instance and therefore not
  /// be unique.
  // ignore: prefer_const_constructors_in_immutables never use const for this class
  _UniqueKey();

  @override
  String toString() => '[#${hashCode.toRadixString(16).padLeft(5, '0')}]';
}
