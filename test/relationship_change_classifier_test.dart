import 'package:autonitor/core/relationship_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? classify({
    required bool wasFollower,
    required bool wasFollowing,
    required bool isNowFollower,
    required bool isNowFollowing,
    String oldStatus = 'normal',
    String oldKeptStatus = 'normal',
    String currentStatus = 'normal',
  }) => classifyKeptRelationshipChange(
    wasFollower: wasFollower,
    wasFollowing: wasFollowing,
    isNowFollower: isNowFollower,
    isNowFollowing: isNowFollowing,
    oldStatus: oldStatus,
    oldKeptStatus: oldKeptStatus,
    currentStatus: currentStatus,
  );

  test('classifies a followed user following back as be_followed_back', () {
    expect(
      classify(
        wasFollower: false,
        wasFollowing: true,
        isNowFollower: true,
        isNowFollowing: true,
      ),
      'be_followed_back',
    );
  });

  test('classifies following a current follower as be_followed_back', () {
    expect(
      classify(
        wasFollower: true,
        wasFollowing: false,
        isNowFollower: true,
        isNowFollowing: true,
      ),
      'be_followed_back',
    );
  });

  test('classifies re-following a previously unfollowed user as recovered', () {
    expect(
      classify(
        wasFollower: false,
        wasFollowing: false,
        isNowFollower: false,
        isNowFollowing: true,
        oldStatus: 'normal_unfollowed',
      ),
      'recovered',
    );
  });

  test('does not classify a follower-only change as recovery', () {
    expect(
      classify(
        wasFollower: false,
        wasFollowing: false,
        isNowFollower: true,
        isNowFollowing: false,
        oldStatus: 'normal_unfollowed',
      ),
      isNull,
    );
  });

  group('classifyRemovedRelationshipChange', () {
    test('reports a mutual relationship as mutual_unfollowed', () {
      expect(
        classifyRemovedRelationshipChange(
          apiStatus: 'normal',
          wasFollower: true,
          wasFollowing: true,
        ),
        'mutual_unfollowed',
      );
    });

    test('reports a follower-only relationship as normal_unfollowed', () {
      expect(
        classifyRemovedRelationshipChange(
          apiStatus: 'normal',
          wasFollower: true,
          wasFollowing: false,
        ),
        'normal_unfollowed',
      );
    });

    test('keeps the relationship verdict when the status lookup failed', () {
      expect(
        classifyRemovedRelationshipChange(
          apiStatus: 'lookup_failed',
          wasFollower: true,
          wasFollowing: true,
        ),
        'mutual_unfollowed',
      );
      expect(
        classifyRemovedRelationshipChange(
          apiStatus: null,
          wasFollower: true,
          wasFollowing: false,
        ),
        'normal_unfollowed',
      );
    });

    test('reports API verdicts even when the user was mutual', () {
      expect(
        classifyRemovedRelationshipChange(
          apiStatus: 'suspended',
          wasFollower: true,
          wasFollowing: true,
        ),
        'suspended',
      );
      expect(
        classifyRemovedRelationshipChange(
          apiStatus: 'deactivated',
          wasFollower: true,
          wasFollowing: false,
        ),
        'deactivated',
      );
      expect(
        classifyRemovedRelationshipChange(
          apiStatus: 'temporarily_restricted',
          wasFollower: false,
          wasFollowing: true,
        ),
        'temporarily_restricted',
      );
    });

    test('never invents a relationship when nothing is known', () {
      expect(
        classifyRemovedRelationshipChange(
          apiStatus: 'lookup_failed',
          wasFollower: false,
          wasFollowing: false,
        ),
        'other_reasons',
      );
    });
  });
}
