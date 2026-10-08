/// Picture size against upload speed, as on the server's room page.
///
/// Left alone, the encoder keeps sending the full camera size even when the
/// connection only allows a few hundred kbit/s, and the picture breaks into
/// blocks. A smaller picture at the same bitrate is much sharper. The camera
/// still captures 960×540 and the encoder scales it down.
class VideoLevel {
  const VideoLevel(this.scale, this.minKbps, this.label);

  /// How much the encoder scales the camera down (scaleResolutionDownBy).
  final double scale;

  /// The upload estimate needed for this level.
  final int minKbps;
  final String label;
}

const videoLevels = [
  VideoLevel(1, 1000, '960×540'),
  VideoLevel(1.5, 450, '640×360'),
  VideoLevel(2, 0, '480×270'),
];

/// Decides when to change level: down at once when the estimate falls, up
/// one level at a time, and only after the estimate has cleared the next
/// level's bar by 30% for [upVotesNeeded] samples in a row (one a second).
class VideoLevelPolicy {
  VideoLevelPolicy({this.level = startLevel});

  /// 640×360 until the estimate shows there's room for more.
  static const startLevel = 1;
  static const upVotesNeeded = 3;

  int level;
  int _upVotes = 0;

  /// Takes one upload estimate sample and returns the new level, or null to
  /// stay at the current one.
  int? sample(int? availableKbps) {
    if (availableKbps == null || availableKbps <= 0) return null;
    final fits = videoLevels.indexWhere((l) => availableKbps >= l.minKbps);
    if (fits > level) {
      _upVotes = 0;
      return level = fits;
    }
    if (fits < level && availableKbps >= videoLevels[level - 1].minKbps * 1.3) {
      if (++_upVotes >= upVotesNeeded) {
        _upVotes = 0;
        return level = level - 1;
      }
      return null;
    }
    _upVotes = 0;
    return null;
  }
}
