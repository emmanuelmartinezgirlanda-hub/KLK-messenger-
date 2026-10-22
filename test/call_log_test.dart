import 'package:flutter_test/flutter_test.dart';
import 'package:klk/features/calls/call_log.dart';

void main() {
  test('CallRecord ida y vuelta', () {
    final r = CallRecord(
      id: '1',
      chatId: 'abc',
      at: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      video: true,
      incoming: true,
      missed: true,
    );
    final back = CallRecord.tryParse(r.toJson())!;
    expect(back.chatId, 'abc');
    expect(back.video, isTrue);
    expect(back.missedIncoming, isTrue);
    expect(back.durationMs, 0);
    expect(CallRecord.tryParse({'i': 1}), isNull);
    expect(CallRecord.tryParse('x'), isNull);
  });
}
