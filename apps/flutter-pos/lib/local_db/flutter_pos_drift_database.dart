// Giai đoạn 8: Drift SQLite ORM Schema cho Flutter POS (Android/iOS)
// Định nghĩa SyncOutboxTable (15+ cột chuẩn), LocalOrdersTable, LocalOrderItemsTable,
// LocalPaymentsTable, LocalServicePositionsTable, LocalCashShiftsTable.

class SyncOutboxTable extends Table {
  TextColumn get operationId => text()();
  IntColumn get sequenceNo => integer().autoIncrement()();
  TextColumn get deviceId => text()();
  TextColumn get userId => text()();
  TextColumn get organizationId => text()();
  TextColumn get storeId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operationType => text()();
  IntColumn get baseVersion => integer().withDefault(const Constant(0))();
  IntColumn get payloadVersion => integer().withDefault(const Constant(1))();
  TextColumn get payloadJson => text()();
  TextColumn get syncStatus => text().withDefault(const Constant('PENDING'))();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get nextRetryAt => text().nullable()();
  TextColumn get errorCategory => text().nullable()();
  TextColumn get lastError => text().nullable()();
  TextColumn get conflictId => text().nullable()();
  TextColumn get serverAcknowledgedAt => text().nullable()();
}
