// Copyright 2022 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:devtools_app_shared/service.dart';
import 'package:devtools_app_shared/ui.dart';
import 'package:devtools_app_shared/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../service/service_extension_widgets.dart';
import '../../../../service/service_extensions.dart' as extensions;
import '../../../../shared/analytics/constants.dart' as gac;
import '../../../../shared/common_widgets.dart';
import '../../../../shared/globals.dart';
import '../../../../shared/primitives/utils.dart';
import '../../../../shared/table/table.dart';
import '../../../../shared/table/table_data.dart';
import '../flutter_frames/flutter_frame_model.dart';
import 'rebuild_stats_model.dart';

class RebuildStatsView extends StatefulWidget {
  const RebuildStatsView({
    Key? key,
    required this.model,
    required this.selectedFrame,
  }) : super(key: key);

  final RebuildCountModel model;
  final ValueListenable<FlutterFrame?> selectedFrame;

  @override
  State<RebuildStatsView> createState() => _RebuildStatsViewState();
}

class _RebuildStatsViewState extends State<RebuildStatsView>
    with AutoDisposeMixin {
  var metricNames = const <String>[];
  var metrics = const <RebuildLocationStats>[];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant RebuildStatsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model ||
        oldWidget.selectedFrame != widget.selectedFrame) {
      cancelListeners();
      _init();
    }
  }

  void _init() {
    addAutoDisposeListener(widget.model.locationStats, computeMetrics);
    addAutoDisposeListener(widget.selectedFrame, computeMetrics);
    computeMetrics();
  }

  void computeMetrics() {
    final names = <String>[];
    final data = <List<RebuildLocation>>[];
    final selectedFrame = widget.selectedFrame.value;

    List<RebuildLocation>? rebuildsForFrame;
    if (selectedFrame != null) {
      rebuildsForFrame = widget.model.rebuildsForFrame(selectedFrame.id);
    }
    if (rebuildsForFrame != null) {
      names.add('Selected frame');
      data.add(rebuildsForFrame);
    } else if (selectedFrame == null) {
      final rebuildsForLastFrame = widget.model.rebuildsForLastFrame;
      if (rebuildsForLastFrame != null) {
        names.add('Latest frame');
        data.add(rebuildsForLastFrame);
      }
    }

    names.add('Overall');
    data.add(widget.model.locationStats.value);

    setState(() {
      metrics = combineStats(data);
      metricNames = names;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlineDecoration.onlyBottom(
          child: Padding(
            padding: const EdgeInsets.all(denseSpacing),
            child: Row(
              children: [
                ClearButton(
                  gaScreen: gac.performance,
                  gaSelection: gac.PerformanceEvents.clearRebuildStats.name,
                  onPressed: widget.model.clearAllCounts,
                ),
                const SizedBox(width: denseSpacing),
                Flexible(
                  child: ServiceExtensionCheckbox(
                    serviceExtension: extensions.trackRebuildWidgets,
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<ServiceExtensionState>(
            valueListenable:
                serviceManager.serviceExtensionManager.getServiceExtensionState(
              extensions.trackRebuildWidgets.extension,
            ),
            builder: (context, state, _) {
              if (metrics.isEmpty && !state.enabled) {
                return const Center(
                  child: Text(
                    'Track widget build counts must be enabled to see data.',
                  ),
                );
              }
              if (metrics.isEmpty) {
                return const Center(
                  child: Text(
                    'Interact with the app to trigger rebuilds.',
                  ),
                ); // No data to display but there should be data soon.
              }
              return RebuildTable(
                key: const Key('Rebuild Table'),
                metricNames: metricNames,
                metrics: metrics,
              );
            },
          ),
        ),
      ],
    );
  }
}

class RebuildTable extends StatefulWidget {
  const RebuildTable({
    Key? key,
    required this.metricNames,
    required this.metrics,
  }) : super(key: key);

  final List<String> metricNames;
  final List<RebuildLocationStats> metrics;

  @override
  State<RebuildTable> createState() => _RebuildTableState();
}

class _RebuildTableState extends State<RebuildTable> {
  SortDirection sortDirection = SortDirection.descending;

  /// Cache of columns so we don't confuse the Table by returning different
  /// column objects for the same column.
  final _columnCache = <String, _RebuildCountColumn>{};

  List<_RebuildCountColumn> get _metricsColumns {
    final columns = <_RebuildCountColumn>[];
    for (var i = 0; i < widget.metricNames.length; i++) {
      final name = widget.metricNames[i];
      var cached = _columnCache[name];
      if (cached == null || cached.metricIndex != i) {
        cached = _RebuildCountColumn(name, i);
        _columnCache[name] = cached;
      }
      columns.add(cached);
    }
    return columns;
  }

  static final _widgetColumn = _WidgetColumn();
  static final _locationColumn = _LocationColumn();

  List<ColumnData<RebuildLocationStats>> get _columns =>
      [_widgetColumn, ..._metricsColumns, _locationColumn];

  @override
  Widget build(BuildContext context) {
    final borderSide = defaultBorderSide(Theme.of(context));
    return Container(
      decoration: BoxDecoration(
        border: Border(right: borderSide),
      ),
      child: FlatTable<RebuildLocationStats>(
        dataKey: 'RebuildMetricsTable',
        columns: _columns,
        data: widget.metrics,
        keyFactory: (RebuildLocationStats location) =>
            ValueKey<String?>('${location.location.id}'),
        defaultSortColumn: _metricsColumns.first,
        defaultSortDirection: sortDirection,
        onItemSelected: (item) {
          // TODO(jacobr): navigate to selected widget in IDE or display the
          // content side by side with the rebuild table.
        },
      ),
    );
  }
}

class _WidgetColumn extends ColumnData<RebuildLocationStats> {
  _WidgetColumn()
      : super(
          'Widget',
          fixedWidthPx: scaleByFontFactor(200),
        );

  @override
  String getValue(RebuildLocationStats dataObject) {
    return dataObject.location.name ?? '???';
  }
}

class _LocationColumn extends ColumnData<RebuildLocationStats> {
  _LocationColumn() : super.wide('Location');

  @override
  String getValue(RebuildLocationStats dataObject) {
    final path = dataObject.location.path;
    if (path == null) {
      return '<resolving location>';
    }

    return '${path.split('/').last}:${dataObject.location.line}';
  }

  @override
  String getTooltip(RebuildLocationStats dataObject) {
    if (dataObject.location.path == null) {
      return '<resolving location>';
    }

    return '${dataObject.location.path}:${dataObject.location.line}';
  }
}

class _RebuildCountColumn extends ColumnData<RebuildLocationStats> {
  _RebuildCountColumn(String name, this.metricIndex)
      : super(
          name,
          fixedWidthPx: scaleByFontFactor(130),
        );

  final int metricIndex;

  @override
  int getValue(RebuildLocationStats dataObject) =>
      dataObject.buildCounts[metricIndex];

  @override
  bool get numeric => true;
}
