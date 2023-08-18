// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:devtools_app_shared/service_extensions.dart' as extensions;
import 'package:devtools_app_shared/ui.dart';
import 'package:devtools_shared/devtools_shared.dart';
import 'package:flutter/material.dart';

import '../shared/analytics/constants.dart' as gac;

class RegisteredServiceDescription extends RegisteredService {
  const RegisteredServiceDescription._({
    required String service,
    required String title,
    this.icon,
    this.gaScreenName,
    this.gaItem,
  }) : super(service: service, title: title);

  final Widget? icon;
  final String? gaScreenName;
  final String? gaItem;
}

/// Hot reload service registered by Flutter Tools.
///
/// We call this service to perform hot reload.
final hotReload = RegisteredServiceDescription._(
  service: extensions.hotReloadServiceName,
  title: 'Hot Reload',
  icon: Icon(
    Icons.electric_bolt_outlined,
    size: actionsIconSize,
  ),
  gaScreenName: gac.devToolsMain,
  gaItem: gac.hotReload,
);

/// Hot restart service registered by Flutter Tools.
///
/// We call this service to perform a hot restart.
final hotRestart = RegisteredServiceDescription._(
  service: extensions.hotRestartServiceName,
  title: 'Hot Restart',
  icon: Icon(
    Icons.settings_backup_restore_outlined,
    size: actionsIconSize,
  ),
  gaScreenName: gac.devToolsMain,
  gaItem: gac.hotRestart,
);

RegisteredService get flutterMemoryInfo => flutterMemory;

const flutterListViews = '_flutter.listViews';

const displayRefreshRate = '_flutter.getDisplayRefreshRate';

String get flutterEngineEstimateRasterCache => flutterEngineRasterCache;

const renderFrameWithRasterStats = '_flutter.renderFrameWithRasterStats';

/// Dwds listens to events for recording end-to-end analytics.
const dwdsSendEvent = 'ext.dwds.sendEvent';
