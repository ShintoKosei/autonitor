import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import '../models/graphql_operation.dart';

class GraphQLService {
  final Dio _dio;
  static const String _jsonUrl =
      'https://raw.githubusercontent.com/fa0311/TwitterInternalAPIDocument/refs/heads/develop/docs/json/GraphQL.json';
  static const List<String> _targetOperations = [
    'UserByRestId',
    'UsersByRestIds',
    'UserByScreenName',
    'UsersByScreenNames',
    'Followers',
    'Following',
  ];

  GraphQLService(this._dio);

  Future<List<GraphQLOperation>> fetchAndParseOperations() async {
    try {
      final response = await _dio.get(_jsonUrl);
      if (response.statusCode != 200) {
        throw Exception('Failed to fetch GraphQL JSON: ${response.statusCode}');
      }

      final dynamic rawData = response.data;
      final List<dynamic> jsonList = rawData is String
          ? jsonDecode(rawData) as List<dynamic>
          : rawData as List<dynamic>;
      final List<GraphQLOperation> operations = [];

      for (var item in jsonList) {
        final exports = item['exports'];
        if (exports != null && exports['operationName'] != null) {
          final String operationName = exports['operationName'];
          if (_targetOperations.contains(operationName)) {
            final String queryId = exports['queryId'];
            final metadata = exports['metadata'];
            final featureSwitches =
                (metadata is Map && metadata['featureSwitches'] is List)
                ? (metadata['featureSwitches'] as List)
                      .map((e) => e.toString())
                      .toList()
                : const <String>[];
            final fieldToggles =
                (metadata is Map && metadata['fieldToggles'] is List)
                ? (metadata['fieldToggles'] as List)
                      .map((e) => e.toString())
                      .toList()
                : const <String>[];
            operations.add(
              GraphQLOperation(
                queryId: queryId,
                operationName: operationName,
                featureSwitches: featureSwitches,
                fieldToggles: fieldToggles,
              ),
            );
          }
        }
      }
      return operations;
    } on DioException catch (e) {
      // 更好的错误处理
      throw Exception('Dio error fetching GraphQL data: ${e.message}');
    }
  }
}

final dioProvider = Provider((ref) => Dio());
final graphQLServiceProvider = Provider(
  (ref) => GraphQLService(ref.read(dioProvider)),
);
