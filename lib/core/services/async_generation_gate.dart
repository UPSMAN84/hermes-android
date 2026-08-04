class AsyncGenerationGate {
  int _generation = 0;

  int begin() => ++_generation;
  void cancel() => _generation++;
  bool isCurrent(int generation) => generation == _generation;
}
