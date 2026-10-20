// Giai đoạn 8: Background Isolate Sync Engine cho Flutter POS
import 'dart:isolate';

void syncWorkerIsolateEntryPoint(SendPort sendPortToMain) {
  final receivePort = ReceivePort();
  sendPortToMain.send(receivePort.sendPort);
  // Lắng nghe lệnh PAUSE / RESUME / SYNC_NOW độc lập hoàn toàn với UI Thread
}
