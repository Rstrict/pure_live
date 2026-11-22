import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/domains/live/domain/live_player_facade.dart';

/// The signed-URL lease is what ends a Douyu stream at five minutes.
///
/// Measured on room 3168536 (hw-h5 line): a continuous read returns FLV tags for
/// exactly 300 s and then hits a clean EOF at +300 s, twice in a row. Appending
/// `&expire=0` keeps the same 300 s close, and rewriting the field is answered
/// with 403 — so the only way past the deadline is to ask the platform for a new
/// signature before the old one closes.
void main() {
  group('leaseRenewDelay', () {
    final issued = DateTime.utc(2026, 11, 21, 12);

    test('a 300 s lease is renewed 30 s early', () {
      // Douyu's measured lease. Ten percent of 300 s is 30 s, well under the
      // 45 s cap, so the margin tracks the lease instead of a fixed value.
      expect(
        LivePlayerFacade.leaseRenewDelay(refreshAt: issued.add(const Duration(seconds: 300)), now: issued),
        const Duration(seconds: 270),
      );
    });

    test('a long lease holds its renewal at the cap', () {
      // An hour-long token: a tenth would be six minutes of unused signature,
      // which is what the cap exists to prevent.
      expect(
        LivePlayerFacade.leaseRenewDelay(refreshAt: issued.add(const Duration(hours: 1)), now: issued),
        const Duration(minutes: 60) - const Duration(seconds: 45),
      );
    });

    test('a short lease keeps a proportional margin', () {
      // Ten percent of 60 s is 6 s: small, but the reopen is local and the
      // buffer covers it. What must not happen is a fixed 45 s margin on a
      // 60 s token, which would renew the source before it ever played.
      expect(
        LivePlayerFacade.leaseRenewDelay(refreshAt: issued.add(const Duration(seconds: 60)), now: issued),
        const Duration(seconds: 54),
      );
    });

    test('a lease already at or past its deadline renews immediately', () {
      expect(LivePlayerFacade.leaseRenewDelay(refreshAt: issued, now: issued), Duration.zero);
      expect(
        LivePlayerFacade.leaseRenewDelay(refreshAt: issued.subtract(const Duration(seconds: 5)), now: issued),
        Duration.zero,
      );
    });

    test('the deadline is compared in UTC regardless of the input zone', () {
      // The stamp comes from the platform clock and is stored as UTC, but a
      // caller may hand over a local DateTime for the same instant.
      final local = issued.add(const Duration(seconds: 300)).toLocal();
      expect(
        LivePlayerFacade.leaseRenewDelay(refreshAt: local, now: issued),
        const Duration(seconds: 270),
      );
    });
  });
}
