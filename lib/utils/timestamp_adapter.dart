import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';

/// Hive TypeAdapter to allow writing and reading Firestore [Timestamp] objects
/// directly in Hive boxes without 'HiveError: Cannot write, unknown type: Timestamp'.
class TimestampAdapter extends TypeAdapter<Timestamp> {
  @override
  final int typeId = 42;

  @override
  Timestamp read(BinaryReader reader) {
    final seconds = reader.readInt();
    final nanoseconds = reader.readInt();
    return Timestamp(seconds, nanoseconds);
  }

  @override
  void write(BinaryWriter writer, Timestamp obj) {
    writer.writeInt(obj.seconds);
    writer.writeInt(obj.nanoseconds);
  }
}
