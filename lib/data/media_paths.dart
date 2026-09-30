import 'package:path/path.dart' as p;

/// Photos and videos live under `<documents>/media/<profile id>/`, and are
/// stored as paths relative to the documents folder ("media/3/12_….jpg").
/// On iOS that folder's absolute location changes whenever the app is
/// reinstalled or updated, so absolute paths would break.
String resolveMediaPath(String documentsPath, String uri) =>
    p.isAbsolute(uri) ? uri : p.join(documentsPath, uri);

/// Turns absolute media paths (from before paths were relative, or from old
/// backups) into relative ones.
const relativizeMediaPathsSql =
    "UPDATE exercise_media SET uri = substr(uri, instr(uri, '/media/') + 1) "
    "WHERE kind <> 'link' AND instr(uri, '/media/') > 0";
