class GraphQLOperation {
  final String queryId;
  final String operationName;
  final List<String> featureSwitches;
  final List<String> fieldToggles;

  GraphQLOperation({
    required this.queryId,
    required this.operationName,
    this.featureSwitches = const [],
    this.fieldToggles = const [],
  });

  @override
  String toString() => '$operationName: $queryId';
}

enum QueryIdSource { apiDocument, custom }
