// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

package com.wiretune.platform

import androidx.core.content.FileProvider

/**
 * Hands other apps the files the user shares from Wiretune (the log), from the one folder `res/xml/wiretune_shared.xml`
 * names, and only while the share lasts. A class of its own: two libraries declaring androidx's FileProvider itself
 * would clash in the app's manifest.
 */
class WiretuneFileProvider : FileProvider()
