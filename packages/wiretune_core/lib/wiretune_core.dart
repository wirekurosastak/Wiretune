// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

/// The shared part of Wiretune, used by the server and by every player.
library;

export 'src/about.dart';
export 'src/audio/audio_driver.dart';
export 'src/audio/audio_engine.dart';
export 'src/audio/pcm_cache.dart';
export 'src/audio/spectrum_analyzer.dart';
export 'src/data/database_manager.dart';
export 'src/data/library_repository.dart';
export 'src/localization/localizer.dart';
export 'src/localization/strings.dart' show allStrings;
export 'src/metadata/tag_reader.dart';
export 'src/models/audio_format.dart';
export 'src/models/library_models.dart';
export 'src/models/protocol.dart';
export 'src/models/remote.dart';
export 'src/services/app_paths.dart';
export 'src/services/artist_picture_service.dart';
export 'src/services/download_service.dart';
export 'src/services/folder_watch.dart';
export 'src/services/library_service.dart';
export 'src/services/lrc_parser.dart';
export 'src/services/metadata_scanner.dart';
export 'src/services/online_lyrics.dart';
export 'src/services/remote_client.dart';
export 'src/services/server_client.dart';
export 'src/services/server_session.dart';
export 'src/services/track_deduplication.dart';
export 'src/services/update_check.dart';
export 'src/services/wiretune_log.dart';
export 'src/util/async_lock.dart';
export 'src/util/cancellation.dart';
export 'src/util/event.dart';
export 'src/util/sorting.dart';
export 'src/util/text.dart';
export 'src/util/time.dart';
