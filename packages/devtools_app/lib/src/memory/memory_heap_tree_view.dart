// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math';

import 'package:devtools_shared/devtools_shared.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auto_dispose_mixin.dart';
import '../common_widgets.dart';
import '../config_specific/logger/logger.dart' as logger;
import '../globals.dart';
import '../split.dart';
import '../table.dart';
import '../table_data.dart';
import '../theme.dart';
import '../ui/icons.dart';
import '../ui/label.dart';
import '../ui/search.dart';
import '../utils.dart';
import 'memory_allocation_table_view.dart';
import 'memory_analyzer.dart';
import 'memory_controller.dart';
import 'memory_filter.dart';
import 'memory_graph_model.dart';
import 'memory_heap_treemap.dart';
import 'memory_instance_tree_view.dart';
import 'memory_screen.dart';
import 'memory_snapshot_models.dart';

const memorySearchFieldKeyName = 'MemorySearchFieldKey';
final memorySearchFieldKey = GlobalKey(debugLabel: memorySearchFieldKeyName);

class HeapTree extends StatefulWidget {
  const HeapTree(
    this.controller,
  );

  final MemoryController controller;

  @override
  HeapTreeViewState createState() => HeapTreeViewState();
}

enum SnapshotStatus {
  none,
  streaming,
  graphing,
  grouping,
  done,
}

enum WildcardMatch {
  exact,
  startsWith,
  endsWith,
  contains,
}

/// If no wildcard then exact match.
/// *NNN - ends with NNN
/// NNN* - starts with NNN
/// NNN*ZZZ - starts with NNN and ends with ZZZ
const knowClassesToAnalyzeForImages = <WildcardMatch, List<String>>{
  // Anything that contains the phrase:
  WildcardMatch.contains: [
    'Image',
  ],

  // Anything that starts with:
  WildcardMatch.startsWith: [],

  // Anything that exactly matches:
  WildcardMatch.exact: [
    '_Int32List',
    // 32-bit devices e.g., emulators, Pixel 2, raw images as Int32List.
    '_Int64List',
    // 64-bit devices e.g., Pixel 3 XL, raw images as Int64List.
    'FrameInfos',
  ],

  // Anything that ends with:
  WildcardMatch.endsWith: [],
};

/// RegEx expressions to handle the WildcardMatches:
///     Ends with Image:      \[_A-Za-z0-9_]*Image\$
///     Starts with Image:    ^Image
///     Contains Image:       Image
///     Extact Image:         ^Image$
String buildRegExs(Map<WildcardMatch, List<String>> matchingCriteria) {
  final resultRegEx = StringBuffer();
  matchingCriteria.forEach((key, value) {
    if (value.isNotEmpty) {
      final name = value;
      String regEx;
      // TODO(terry): Need to handle $ for identifier names e.g.,
      //              $FOO is a valid identifier.
      switch (key) {
        case WildcardMatch.exact:
          regEx = '^${name.join("\$|^")}\$';
          break;
        case WildcardMatch.startsWith:
          regEx = '^${name.join("|^")}';
          break;
        case WildcardMatch.endsWith:
          regEx = '^\[_A-Za-z0-9]*${name.join("\|[_A-Za-z0-9]*")}\$';
          break;
        case WildcardMatch.contains:
          regEx = '${name.join("|")}';
          break;
        default:
          assert(false, 'buildRegExs: Unhandled WildcardMatch');
      }
      resultRegEx.write(resultRegEx.isEmpty ? '($regEx' : '|$regEx');
    }
  });

  resultRegEx.write(')');
  return resultRegEx.toString();
}

final String knownClassesRegExs = buildRegExs(knowClassesToAnalyzeForImages);

class HeapTreeViewState extends State<HeapTree>
    with
        AutoDisposeMixin,
        SearchFieldMixin<HeapTree>,
        SingleTickerProviderStateMixin {
  @visibleForTesting
  static const snapshotButtonKey = Key('Snapshot Button');
  @visibleForTesting
  static const groupByClassButtonKey = Key('Group By Class Button');
  @visibleForTesting
  static const groupByLibraryButtonKey = Key('Group By Library Button');
  @visibleForTesting
  static const collapseAllButtonKey = Key('Collapse All Button');
  @visibleForTesting
  static const expandAllButtonKey = Key('Expand All Button');
  @visibleForTesting
  static const allocationMonitorKey = Key('Allocation Monitor Start Button');
  @visibleForTesting
  static const allocationMonitorResetKey = Key('Accumulators Reset Button');
  @visibleForTesting
  static const searchButtonKey = Key('Snapshot Search');
  @visibleForTesting
  static const filterButtonKey = Key('Snapshot Filter');
  @visibleForTesting
  static const dartHeapAnalysisTabKey = Key('Dart Heap Analysis Tab');
  @visibleForTesting
  static const dartHeapAllocationsTabKey = Key('Dart Heap Allocations Tab');

  /// Below constants should match index for Tab index in DartHeapTabs.
  static const int analysisTabIndex = 0;
  static const int allocationsTabIndex = 1;

  static const List<Tab> DartHeapTabs = [
    Tab(key: dartHeapAnalysisTabKey, text: 'Analysis'),
    Tab(key: dartHeapAllocationsTabKey, text: 'Allocations'),
  ];

  MemoryController controller;

  TabController tabController;

  Widget snapshotDisplay;

  /// Used to detect a spike in memory usage.
  MovingAverage heapMovingAverage = MovingAverage(averagePeriod: 100);

  /// Number of seconds between auto snapshots because RSS is exceeded.
  static const maxRSSExceededDurationSecs = 30;

  static const minPercentIncrease = 30;

  /// Timestamp of HeapSample that caused auto snapshot.
  int spikeSnapshotTime;

  /// Timestamp when RSS exceeded auto snapshot.
  int rssSnapshotTime = 0;

  /// Total memory that caused last snapshot.
  int lastSnapshotMemoryTotal = 0;

  bool treeMapVisible;

  @override
  void initState() {
    super.initState();

    tabController = TabController(length: DartHeapTabs.length, vsync: this);
    addAutoDisposeListener(tabController);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final newController = Provider.of<MemoryController>(context);
    if (newController == controller) return;

    controller = newController;

    cancel();

    addAutoDisposeListener(controller.selectedSnapshotNotifier, () {
      setState(() {
        controller.computeAllLibraries(rebuild: true);
      });
    });

    addAutoDisposeListener(controller.selectionSnapshotNotifier, () {
      setState(() {
        controller.computeAllLibraries(rebuild: true);
      });
    });

    addAutoDisposeListener(controller.filterNotifier, () {
      setState(() {
        controller.computeAllLibraries(rebuild: true);
      });
    });

    addAutoDisposeListener(controller.leafSelectedNotifier, () {
      setState(() {
        controller.computeRoot();
      });
    });

    addAutoDisposeListener(controller.leafAnalysisSelectedNotifier, () {
      setState(() {
        controller.computeAnalysisInstanceRoot();
      });
    });

    addAutoDisposeListener(controller.searchNotifier, () {
      setState(() {
        controller.closeAutoCompleteOverlay();
        controller.currentDefaultIndex = 0;
      });
    });

    addAutoDisposeListener(controller.searchAutoCompleteNotifier, () {
      SnapshotFilterState.gaActionForSnapshotFilterDialog();
      setState(controller.autoCompleteOverlaySetState(
        context: context,
        searchFieldKey: memorySearchFieldKey,
      ));
    });

    addAutoDisposeListener(controller.monitorAllocationsNotifier, () {
      setState(() {
        controller.computeAllLibraries(rebuild: true);
      });
    });

    addAutoDisposeListener(controller.memoryTimeline.sampleAddedNotifier, () {
      autoSnapshot();
    });

    treeMapVisible = controller.treeMapVisible.value;
    addAutoDisposeListener(controller.treeMapVisible, () {
      setState(() {
        treeMapVisible = controller.treeMapVisible.value;
      });
    });
  }

  @override
  void dispose() {
    // Clean up the TextFieldController and FocusNode.
    searchTextFieldController.dispose();
    searchFieldFocusNode.dispose();

    rawKeyboardFocusNode.dispose();

    super.dispose();
  }

  /// Enable to output debugging information for auto-snapshot.
  /// WARNING: Do not checkin with this flag set to true.
  final debugSnapshots = false;

  /// Detect spike in memory usage if so do an automatic snapshot.
  void autoSnapshot() {
    final heapSample = controller.memoryTimeline.sampleAddedNotifier.value;
    final heapSum = heapSample.external + heapSample.used;
    heapMovingAverage.add(heapSum);

    final dateTimeFormat = DateFormat('hh:mm:ss.mmm');
    final startDateTime = dateTimeFormat
        .format(DateTime.fromMillisecondsSinceEpoch(heapSample.timestamp));

    if (debugSnapshots) {
      debugLogger('AutoSnapshot $startDateTime heapSum=$heapSum, '
          'first=${heapMovingAverage.dataSet.first}, '
          'mean=${heapMovingAverage.mean}');
    }

    bool takeSnapshot = false;
    final sampleTime = Duration(milliseconds: heapSample.timestamp);

    final rssExceeded = heapSample.rss != null && heapSum > heapSample.rss;
    if (rssExceeded) {
      final increase = heapSum - lastSnapshotMemoryTotal;
      final rssPercentIncrease = lastSnapshotMemoryTotal > 0
          ? increase / lastSnapshotMemoryTotal * 100
          : 0;
      final rssTime = Duration(milliseconds: rssSnapshotTime);
      // Number of seconds since last snapshot happens because of RSS exceeded.
      // Reduce rapid fire snapshots.
      final rssSnapshotPeriod = (sampleTime - rssTime).inSeconds;
      if (rssSnapshotPeriod > maxRSSExceededDurationSecs) {
        // minPercentIncrease larger than previous auto RSS snapshot then
        // take another snapshot.
        if (rssPercentIncrease > minPercentIncrease) {
          rssSnapshotTime = heapSample.timestamp;
          lastSnapshotMemoryTotal = heapSum;

          takeSnapshot = true;
          debugLogger('AutoSnapshot - RSS exceeded '
              '($rssPercentIncrease% increase) @ $startDateTime.');
        }
      }
    }

    if (!takeSnapshot && heapMovingAverage.hasSpike()) {
      final snapshotTime =
          Duration(milliseconds: spikeSnapshotTime ?? heapSample.timestamp);
      spikeSnapshotTime = heapSample.timestamp;
      takeSnapshot = true;
      logger.log('AutoSnapshot - memory spike @ $startDateTime} '
          'last snapshot ${(sampleTime - snapshotTime).inSeconds} seconds ago.');
      debugLogger('               '
          'heap @ last snapshot = $lastSnapshotMemoryTotal, '
          'heap total=$heapSum, RSS=${heapSample.rss}');
    }

    if (takeSnapshot) {
      assert(!heapMovingAverage.isDipping());
      // Reset moving average for next spike.
      heapMovingAverage.clear();
      // TODO(terry): Should get the real sum of the snapshot not the current memory.
      //              Snapshot can take a bit and could be a lag.
      lastSnapshotMemoryTotal = heapSum;
      _takeHeapSnapshot(userGenerated: false);
    } else if (heapMovingAverage.isDipping()) {
      // Reset the two things we're tracking spikes and RSS exceeded.
      heapMovingAverage.clear();
      lastSnapshotMemoryTotal = heapSum;
    }
  }

  SnapshotStatus snapshotState = SnapshotStatus.none;

  bool get _isSnapshotRunning =>
      snapshotState != SnapshotStatus.done &&
      snapshotState != SnapshotStatus.none;

  bool get _isSnapshotStreaming => snapshotState == SnapshotStatus.streaming;

  bool get _isSnapshotGraphing => snapshotState == SnapshotStatus.graphing;

  bool get _isSnapshotGrouping => snapshotState == SnapshotStatus.grouping;

  bool get _isSnapshotComplete => snapshotState == SnapshotStatus.done;

  @override
  Widget build(BuildContext context) {
    final themeData = Theme.of(context);

    if (_isSnapshotRunning) {
      snapshotDisplay = Column(
        children: [
          const SizedBox(height: 50.0),
          snapshotDisplay = const CircularProgressIndicator(),
          const SizedBox(height: denseSpacing),
          Text(
            _isSnapshotStreaming
                ? 'Processing...'
                : _isSnapshotGraphing
                    ? 'Graphing...'
                    : _isSnapshotGrouping
                        ? 'Grouping...'
                        : _isSnapshotComplete
                            ? 'Done'
                            : '...',
          ),
        ],
      );
    } else if (controller.snapshotByLibraryData != null) {
      snapshotDisplay =
          treeMapVisible ? MemoryHeapTreemap(controller) : MemoryHeapTable();
    } else {
      // TODO: Have some help text about how to take a snapshot.
      snapshotDisplay = const SizedBox();
    }

    return Padding(
      padding: const EdgeInsets.only(top: denseRowSpacing),
      child: Column(
        children: [
          const SizedBox(height: defaultSpacing),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TabBar(
                labelColor: themeData.textTheme.bodyText1.color,
                isScrollable: true,
                controller: tabController,
                tabs: HeapTreeViewState.DartHeapTabs,
              ),
              _buildSearchFilterControls(),
            ],
          ),
          const SizedBox(height: densePadding),
          Expanded(
            child: TabBarView(
              physics: defaultTabBarViewPhysics,
              controller: tabController,
              children: [
                // Analysis Tab
                Column(
                  children: [
                    _buildSnapshotControls(themeData.textTheme),
                    const SizedBox(height: denseRowSpacing),
                    Expanded(
                      child: OutlineDecoration(
                        child: buildSnapshotTables(snapshotDisplay),
                      ),
                    ),
                  ],
                ),

                // Allocations Tab
                Column(
                  children: [
                    _buildAllocationsControls(themeData),
                    const SizedBox(height: denseRowSpacing),
                    const Expanded(
                      child: OutlineDecoration(
                        child: AllocationTableView(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSnapshotTables(Widget snapshotDisplay) {
    final rightSideTable = controller.isLeafSelected
        ? InstanceTreeView()
        : controller.isAnalysisLeafSelected
            ? Expanded(child: AnalysisInstanceViewTable())
            : const SizedBox();

    return treeMapVisible
        ? snapshotDisplay
        : Split(
            initialFractions: const [0.5, 0.5],
            minSizes: const [300, 300],
            axis: Axis.horizontal,
            children: [
              // TODO(terry): Need better focus handling between 2 tables & up/down
              //              arrows in the right-side field instance view table.
              snapshotDisplay,
              rightSideTable,
            ],
          );
  }

  @visibleForTesting
  static const groupByMenuButtonKey = Key('Group By Menu Button');
  @visibleForTesting
  static const groupByMenuItem = Key('Group By Menu Item');
  @visibleForTesting
  static const groupByKey = Key('Group By');

  Widget _groupByDropdown(TextTheme textTheme) {
    final _groupByTypes = [
      MemoryController.groupByLibrary,
      MemoryController.groupByClass,
      MemoryController.groupByInstance,
    ].map<DropdownMenuItem<String>>(
      (
        String value,
      ) {
        return DropdownMenuItem<String>(
          key: groupByMenuItem,
          value: value,
          child: Text(
            'Group by $value',
            key: groupByKey,
          ),
        );
      },
    ).toList();

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: groupByMenuButtonKey,
        style: textTheme.bodyText2,
        value: controller.groupingBy.value,
        onChanged: (String newValue) {
          setState(
            () {
              MemoryScreen.gaAction(name: '${keyName(groupByKey)} $newValue');
              controller.selectedLeaf = null;
              controller.groupingBy.value = newValue;
              if (controller.snapshots.isNotEmpty) {
                doGroupBy();
              }
            },
          );
        },
        items: _groupByTypes,
      ),
    );
  }

  Widget _buildSnapshotControls(TextTheme textTheme) {
    return SizedBox(
      height: defaultButtonHeight,
      child: Row(
        children: [
          FixedHeightOutlinedButton(
            buttonKey: snapshotButtonKey,
            tooltip: 'Take a memory profile snapshot',
            onPressed: _isSnapshotRunning ? null : _takeHeapSnapshot,
            child: const MaterialIconLabel(
              label: 'Take Heap Snapshot',
              iconData: Icons.camera,
            ),
          ),
          const SizedBox(width: defaultSpacing),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Treemap'),
              Switch(
                value: treeMapVisible,
                onChanged: controller.snapshotByLibraryData != null
                    ? (value) {
                        controller.toggleTreeMapVisible(value);
                      }
                    : null,
              ),
            ],
          ),
          if (!treeMapVisible) ...[
            const SizedBox(width: defaultSpacing),
            _groupByDropdown(textTheme),
            const SizedBox(width: defaultSpacing),
            // TODO(terry): Mechanism to handle expand/collapse on both tables
            // objects/fields. Maybe notion in table?
            ExpandAllButton(
              key: expandAllButtonKey,
              onPressed: () {
                MemoryScreen.gaAction(key: expandAllButtonKey);
                if (snapshotDisplay is MemoryHeapTable) {
                  controller.groupByTreeTable.dataRoots.every((element) {
                    element.expandCascading();
                    return true;
                  });
                }
                // All nodes expanded - signal tree state  changed.
                controller.treeChanged();
              },
            ),
            const SizedBox(width: denseSpacing),
            CollapseAllButton(
              key: collapseAllButtonKey,
              onPressed: () {
                MemoryScreen.gaAction(key: collapseAllButtonKey);
                if (snapshotDisplay is MemoryHeapTable) {
                  controller.groupByTreeTable.dataRoots.every((element) {
                    element.collapseCascading();
                    return true;
                  });
                  if (controller.instanceFieldsTreeTable != null) {
                    // We're collapsing close the fields table.
                    controller.selectedLeaf = null;
                  }
                  // All nodes collapsed - signal tree state changed.
                  controller.treeChanged();
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAllocationsControls(ThemeData themeData) {
    return Row(
      children: [
        FixedHeightOutlinedButton(
          buttonKey: allocationMonitorKey,
          tooltip: 'Collect Allocation Statistics',
          onPressed: () async {
            MemoryScreen.gaAction(key: allocationMonitorKey);
            await _allocationStart();
          },
          child: MaterialIconLabel(
            label: 'Track',
            imageIcon: createImageIcon(
              // TODO(terry): Match shape in event pane.
              themeData.isDarkTheme
                  ? 'icons/memory/communities_white.png'
                  : 'icons/memory/communities_black.png',
            ),
          ),
        ),
        const SizedBox(width: denseSpacing),
        FixedHeightOutlinedButton(
          buttonKey: allocationMonitorResetKey,
          tooltip: 'Reset all accumulators',
          onPressed: () async {
            MemoryScreen.gaAction(key: allocationMonitorResetKey);
            await _allocationReset();
          },
          child: MaterialIconLabel(
            label: 'Reset',
            imageIcon: createImageIcon(
              // TODO(terry): Match shape in event pane.
              themeData.isDarkTheme
                  ? 'icons/memory/reset_icon_white.png'
                  : 'icons/memory/reset_icon_black.png',
            ),
          ),
        ),
        const Spacer(),
        Text(
          controller.monitorTimestamp == null
              ? 'No allocations tracked'
              : 'Allocations Tracked at ${MemoryController.formattedTimestamp(controller.monitorTimestamp)}',
          style: themeData.colorScheme.italicTextStyle,
        ),
      ],
    );
  }

  // WARNING: Do not checkin the debug flag set to true.
  final _debugAllocationMonitoring = false;

  Future<void> _allocationStart() async {
    // TODO(terry): Look at grouping by library or classes also filtering e.g.,
    // await controller.computeLibraries();
    controller.memoryTimeline.addMonitorStartEvent();

    final allocationtimestamp = DateTime.now();
    final currentAllocations = await controller.getAllocationProfile();

    if (controller.monitorAllocations.isNotEmpty) {
      final previousSize = controller.monitorAllocations.length;
      int previousIndex = 0;
      final currentSize = currentAllocations.length;
      int currentIndex = 0;
      while (currentIndex < currentSize && previousIndex < previousSize) {
        final previousAllocation = controller.monitorAllocations[previousIndex];
        final currentAllocation = currentAllocations[currentIndex];

        if (previousAllocation.classRef.id == currentAllocation.classRef.id) {
          final instancesCurrent = currentAllocation.instancesCurrent;
          final bytesCurrent = currentAllocation.bytesCurrent;

          currentAllocation.instancesDelta = previousAllocation.instancesDelta +
              (instancesCurrent - previousAllocation.instancesCurrent);
          currentAllocation.bytesDelta = previousAllocation.bytesDelta +
              (bytesCurrent - previousAllocation.bytesCurrent);

          final instancesAccumulated = currentAllocation.instancesDelta;
          final bytesAccumulated = currentAllocation.bytesDelta;

          if (_debugAllocationMonitoring &&
              (instancesAccumulated != 0 || bytesAccumulated != 0)) {
            debugLogger('previous,index=[$previousIndex][$currentIndex] '
                'class ${currentAllocation.classRef.name}\n'
                '    instancesCurrent=$instancesCurrent, '
                '    instancesAccumulated=${currentAllocation.instancesDelta}\n'
                '    bytesCurrent=$bytesCurrent, '
                '    bytesAccumulated=${currentAllocation.bytesDelta}}\n');
          }

          previousIndex++;
          currentIndex++;
        } else {
          // Either a new class in currentAllocations or old that's no longer
          // active in previousAllocations.
          final currentClassId = currentAllocation.classRef.id;
          final ClassHeapDetailStats first =
              controller.monitorAllocations.firstWhere(
            (element) => element.classRef.id == currentClassId,
            orElse: () => null,
          );
          if (first != null) {
            // A class that no longer exist (live or sentinel).
            previousIndex++;
          } else {
            // New Class encountered in new AllocationProfile, don't increment
            // previousIndex.
            currentIndex++;
          }
        }
      }

      // Insure all entries from previous and current monitors were looked at.
      assert(previousSize == previousIndex, '$previousSize == $previousIndex');
      assert(currentSize == currentIndex, '$currentSize == $currentIndex');
    }

    controller.monitorTimestamp = allocationtimestamp;
    controller.monitorAllocations = currentAllocations;

    controller.treeChanged();
  }

  Future<void> _allocationReset() async {
    controller.memoryTimeline.addMonitorResetEvent();
    final currentAllocations = await controller.resetAllocationProfile();

    // Reset all accumulators to zero.
    for (final classAllocation in currentAllocations) {
      classAllocation.bytesDelta = 0;
      classAllocation.instancesDelta = 0;
    }

    controller.monitorAllocations = currentAllocations;
  }

  void highlightDropdown(bool directionDown) {
    final numItems = controller.searchAutoComplete.value.length - 1;
    var indexToSelect = controller.currentDefaultIndex;
    if (directionDown) {
      // Select next item in auto-complete overlay.
      ++indexToSelect;
      if (indexToSelect > numItems) {
        // Greater than max go back to top list item.
        indexToSelect = 0;
      }
    } else {
      // Select previous item item in auto-complete overlay.
      --indexToSelect;
      if (indexToSelect < 0) {
        // Less than first go back to bottom list item.
        indexToSelect = numItems;
      }
    }

    controller.currentDefaultIndex = indexToSelect;

    // Cause the auto-complete list to update, list is small 10 items max.
    controller.searchAutoComplete.value =
        controller.searchAutoComplete.value.toList();
  }

  /// Match, found,  select it and process via ValueNotifiers.
  void selectTheMatch(String foundName) {
    MemoryScreen.gaAction(name: memorySearchFieldKeyName);
    setState(() {
      if (tabController.index == allocationsTabIndex) {
        controller.selectItemInAllocationTable(foundName);
      } else if (tabController.index == analysisTabIndex &&
          snapshotDisplay is MemoryHeapTable) {
        controller.groupByTreeTable.dataRoots.every((element) {
          element.collapseCascading();
          return true;
        });
      }
    });

    selectFromSearchField(controller, foundName);
    clearSearchField(controller);
  }

  bool get _isSearchable {
    // Analysis tab and Snapshot exist or 'Allocations' tab allocations are monitored.
    return (tabController.index == analysisTabIndex && !treeMapVisible) ||
        (tabController.index == allocationsTabIndex &&
            controller.monitorAllocations.isNotEmpty);
  }

  Widget _buildSearchWidget(GlobalKey<State<StatefulWidget>> key) => Container(
        width: wideSearchTextWidth,
        height: defaultTextFieldHeight,
        child: buildAutoCompleteSearchField(
          controller: controller,
          searchFieldKey: key,
          searchFieldEnabled: _isSearchable,
          shouldRequestFocus: _isSearchable,
          onSelection: selectTheMatch,
          onHighlightDropdown: highlightDropdown,
        ),
      );

  Widget _buildSearchFilterControls() => Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _buildSearchWidget(memorySearchFieldKey),
          const SizedBox(width: denseSpacing),
          FilterButton(
            key: filterButtonKey,
            onPressed: _filter,
            // TODO(kenz): implement isFilterActive
            isFilterActive: false,
          ),
        ],
      );

  // TODO: Much of the logic for _takeHeapSnapshot() might want to move into the
  // controller.
  void _takeHeapSnapshot({bool userGenerated = true}) async {
    MemoryScreen.gaAction(key: snapshotButtonKey);

    // VmService not available (disconnected/crashed).
    if (serviceManager.service == null) return;

    // Another snapshot in progress, don't stall the world. An auto-snapshot
    // is probably in progress.
    if (snapshotState != SnapshotStatus.none &&
        snapshotState != SnapshotStatus.done) {
      debugLogger('Snapshot in progress - ignoring this request.');
      return;
    }

    controller.memoryTimeline.addSnapshotEvent(auto: !userGenerated);

    setState(() {
      snapshotState = SnapshotStatus.streaming;
    });

    final snapshotTimestamp = DateTime.now();

    final graph = await controller.snapshotMemory();

    // No snapshot collected, disconnected/crash application.
    if (graph == null) {
      setState(() {
        snapshotState = SnapshotStatus.done;
      });
      controller.selectedSnapshotTimestamp = DateTime.now();
      return;
    }

    final snapshotCollectionTime = DateTime.now();

    setState(() {
      snapshotState = SnapshotStatus.graphing;
    });

    // To debug particular classes add their names to the last
    // parameter classNamesToMonitor e.g., ['AppStateModel', 'Terry', 'TerryEntry']
    controller.heapGraph = convertHeapGraph(
      controller,
      graph,
      [],
    );
    final snapshotGraphTime = DateTime.now();

    setState(() {
      snapshotState = SnapshotStatus.grouping;
    });

    await doGroupBy();

    final root = controller.computeAllLibraries(graph: graph);

    final snapshot = controller.storeSnapshot(
      snapshotTimestamp,
      graph,
      root,
      autoSnapshot: !userGenerated,
    );

    final snapshotDoneTime = DateTime.now();

    controller.selectedSnapshotTimestamp = snapshotTimestamp;

    debugLogger('Total Snapshot completed in'
        ' ${snapshotDoneTime.difference(snapshotTimestamp).inMilliseconds / 1000} seconds');
    debugLogger('  Snapshot collected in'
        ' ${snapshotCollectionTime.difference(snapshotTimestamp).inMilliseconds / 1000} seconds');
    debugLogger('  Snapshot graph built in'
        ' ${snapshotGraphTime.difference(snapshotCollectionTime).inMilliseconds / 1000} seconds');
    debugLogger('  Snapshot grouping/libraries computed in'
        ' ${snapshotDoneTime.difference(snapshotGraphTime).inMilliseconds / 1000} seconds');

    setState(() {
      snapshotState = SnapshotStatus.done;
    });

    controller.buildTreeFromAllData();
    _analyze(snapshot: snapshot);
  }

  Future<void> doGroupBy() async {
    controller.heapGraph
      ..computeInstancesForClasses()
      ..computeRawGroups()
      ..computeFilteredGroups();
  }

  void _filter() {
    MemoryScreen.gaAction(name: 'SnapshotFilterDialog');
    showDialog(
      context: context,
      builder: (BuildContext context) => SnapshotFilterDialog(controller),
    );
  }

  void _debugCheckAnalyses(DateTime currentSnapDateTime) {
    // Debug only check.
    assert(() {
      // Analysis already completed we're done.
      final foundMatch = controller.completedAnalyses.firstWhere(
        (element) => element.dateTime.compareTo(currentSnapDateTime) == 0,
        orElse: () => null,
      );
      if (foundMatch != null) {
        logger.log(
          'Analysis '
          '${MemoryController.formattedTimestamp(currentSnapDateTime)} '
          'already computed.',
          logger.LogLevel.warning,
        );
      }
      return true;
    }());
  }

  void _analyze({Snapshot snapshot}) {
    final AnalysesReference analysesNode = controller.findAnalysesNode();
    assert(analysesNode != null);

    snapshot ??= controller.computeSnapshotToAnalyze;
    final currentSnapDateTime = snapshot?.collectedTimestamp;

    _debugCheckAnalyses(currentSnapDateTime);

    // If there's an empty place holder than remove it. First analysis will
    // exist shortly.
    if (analysesNode.children.length == 1 &&
        analysesNode.children.first.name.isEmpty) {
      analysesNode.children.clear();
    }

    // Create analysis node to hold analysis results.
    final analyzeSnapshot = AnalysisSnapshotReference(currentSnapDateTime);
    analysesNode.addChild(analyzeSnapshot);

    // Analyze this snapshot.
    final collectedData = collect(controller, snapshot);

    // Analyze the collected data.

    // 1. Analysis of memory image usage.
    imageAnalysis(controller, analyzeSnapshot, collectedData);

    // Add to our list of completed analyses.
    controller.completedAnalyses.add(analyzeSnapshot);

    // Expand the 'Analysis' node.
    if (!analysesNode.isExpanded) {
      analysesNode.expand();
    }

    // Select the snapshot just analyzed.
    controller.selectionSnapshotNotifier.value = Selection(
      node: analyzeSnapshot,
      nodeIndex: analyzeSnapshot.index,
      scrollIntoView: true,
    );
  }

  // ignore: unused_element
  void _settings() {
    // TODO(terry): TBD
  }
}

/// Snapshot TreeTable
class MemoryHeapTable extends StatefulWidget {
  @override
  MemoryHeapTableState createState() => MemoryHeapTableState();
}

/// A table of the Memory graph class top-down call tree.
class MemoryHeapTableState extends State<MemoryHeapTable>
    with AutoDisposeMixin {
  MemoryController controller;

  final TreeColumnData<Reference> treeColumn = _LibraryRefColumn();
  final List<ColumnData<Reference>> columns = [];

  @override
  void initState() {
    super.initState();

    // Setup the table columns.
    columns.addAll([
      treeColumn,
      _ClassOrInstanceCountColumn(),
      _ShallowSizeColumn(),
      _RetainedSizeColumn(),
    ]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final newController = Provider.of<MemoryController>(context);
    if (newController == controller) return;
    controller = newController;

    cancel();

    // Update the tree when the tree state changes e.g., expand, collapse, etc.
    addAutoDisposeListener(controller.treeChangedNotifier, () {
      if (controller.isTreeChanged) {
        setState(() {});
      }
    });

    // Update the tree when the memorySource changes.
    addAutoDisposeListener(controller.selectedSnapshotNotifier, () {
      setState(() {
        controller.computeAllLibraries(rebuild: true);
      });
    });

    addAutoDisposeListener(controller.filterNotifier, () {
      setState(() {
        controller.computeAllLibraries(rebuild: true);
      });
    });

    addAutoDisposeListener(controller.searchAutoCompleteNotifier);

    addAutoDisposeListener(controller.selectTheSearchNotifier, _handleSearch);

    addAutoDisposeListener(controller.searchNotifier, _handleSearch);
  }

  void _handleSearch() {
    if (_trySelectItem()) {
      setState(() {
        controller.closeAutoCompleteOverlay();
      });
    }
  }

  List<String> _snapshotMatches(String searchingValue) {
    final matches = <String>[];

    final externalMatches = <String>[];
    final filteredMatches = <String>[];

    switch (controller.groupingBy.value) {
      case MemoryController.groupByLibrary:
        final searchRoot = controller.activeSnapshot;
        for (final reference in searchRoot.children) {
          if (reference.isLibrary) {
            matches.addAll(matchesInLibrary(reference, searchingValue));
          } else if (reference.isExternals) {
            final ExternalReferences refs = reference;
            for (final ExternalReference ext in refs.children) {
              final match = matchSearch(ext, searchingValue);
              if (match != null) {
                externalMatches.add(match);
              }
            }
          } else if (reference.isFiltered) {
            // Matches in the filtered nodes.
            final FilteredReference filteredReference = reference;
            for (final library in filteredReference.children) {
              filteredMatches.addAll(matchesInLibrary(
                library,
                searchingValue,
              ));
            }
          }
        }
        break;
      case MemoryController.groupByClass:
        matches.addAll(matchClasses(
            controller.groupByTreeTable.dataRoots, searchingValue));
        break;
      case MemoryController.groupByInstance:
        // TODO(terry): TBD
        break;
    }

    // Ordered in importance (matches, external, filtered).
    matches.addAll(externalMatches);
    matches.addAll(filteredMatches);
    return matches;
  }

  bool _trySelectItem() {
    final searchingValue = controller.search;
    if (searchingValue.isNotEmpty) {
      if (controller.selectTheSearch) {
        // Found an exact match.
        selectItemInTree(searchingValue);
        controller.selectTheSearch = false;
        controller.resetSearch();
        return true;
      }

      // No exact match, return the list of possible matches.
      controller.clearSearchAutoComplete();

      final matches = _snapshotMatches(searchingValue);

      // Remove duplicates and sort the matches.
      final normalizedMatches = matches.toSet().toList()..sort();
      // Use the top 10 matches:
      controller.searchAutoComplete.value = normalizedMatches.sublist(
          0,
          min(
            topMatchesLimit,
            normalizedMatches.length,
          ));
    }

    return false;
  }

  List<String> _maybeAddMatch(Reference reference, String search) {
    final matches = <String>[];

    final match = matchSearch(reference, search);
    if (match != null) {
      matches.add(match);
    }

    return matches;
  }

  List<String> matchesInLibrary(
    LibraryReference libraryReference,
    String searchingValue,
  ) {
    final matches = _maybeAddMatch(libraryReference, searchingValue);

    final List<Reference> classes = libraryReference.children;
    matches.addAll(matchClasses(classes, searchingValue));

    return matches;
  }

  List<String> matchClasses(
    List<Reference> classReferences,
    String searchingValue,
  ) {
    final matches = <String>[];

    // Check the class names in the library
    for (final ClassReference classReference in classReferences) {
      matches.addAll(_maybeAddMatch(classReference, searchingValue));
    }

    // Remove duplicates
    return matches;
  }

  /// Return null if no match, otherwise string.
  String matchSearch(Reference ref, String matchString) {
    final knownName = ref.name.toLowerCase();
    if (knownName.contains(matchString.toLowerCase())) {
      return ref.name;
    }
    return null;
  }

  /// This finds and selects an exact match in the tree.
  /// Returns `true` if [searchingValue] is found in the tree.
  bool selectItemInTree(String searchingValue) {
    // Search the snapshots.
    switch (controller.groupingBy.value) {
      case MemoryController.groupByLibrary:
        final searchRoot = controller.activeSnapshot;
        if (controller.selectionSnapshotNotifier.value.node == null) {
          // No selected node, then select the snapshot we're searching.
          controller.selectionSnapshotNotifier.value = Selection(
            node: searchRoot,
            nodeIndex: searchRoot.index,
            scrollIntoView: true,
          );
        }
        for (final reference in searchRoot.children) {
          if (reference.isLibrary) {
            final foundIt = _selectItemInTree(reference, searchingValue);
            if (foundIt) {
              return true;
            }
          } else if (reference.isFiltered) {
            // Matches in the filtered nodes.
            final FilteredReference filteredReference = reference;
            for (final library in filteredReference.children) {
              final foundIt = _selectItemInTree(library, searchingValue);
              if (foundIt) {
                return true;
              }
            }
          } else if (reference.isExternals) {
            final ExternalReferences refs = reference;
            for (final ExternalReference external in refs.children) {
              final foundIt = _selectItemInTree(external, searchingValue);
              if (foundIt) {
                return true;
              }
            }
          }
        }
        break;
      case MemoryController.groupByClass:
        for (final reference in controller.groupByTreeTable.dataRoots) {
          if (reference.isClass) {
            return _selecteClassInTree(reference, searchingValue);
          }
        }
        break;
      case MemoryController.groupByInstance:
        // TODO(terry): TBD
        break;
    }

    return false;
  }

  bool _selectInTree(Reference reference, search) {
    if (reference.name == search) {
      controller.selectionSnapshotNotifier.value = Selection(
        node: reference,
        nodeIndex: reference.index,
        scrollIntoView: true,
      );
      controller.clearSearchAutoComplete();
      return true;
    }
    return false;
  }

  bool _selectItemInTree(Reference reference, String searchingValue) {
    // TODO(terry): Only finds first one.
    if (_selectInTree(reference, searchingValue)) return true;

    // Check the class names in the library
    return _selecteClassInTree(reference, searchingValue);
  }

  bool _selecteClassInTree(Reference reference, String searchingValue) {
    // Check the class names in the library
    for (final Reference classReference in reference.children) {
      // TODO(terry): Only finds first one.
      if (_selectInTree(classReference, searchingValue)) return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final root = controller.buildTreeFromAllData();

    if (root != null && root.children.isNotEmpty) {
      // Snapshots and analyses exists display the trees.
      controller.groupByTreeTable = TreeTable<Reference>(
        dataRoots: root.children,
        columns: columns,
        treeColumn: treeColumn,
        keyFactory: (libRef) => PageStorageKey<String>(libRef.name),
        sortColumn: columns[0],
        sortDirection: SortDirection.ascending,
        selectionNotifier: controller.selectionSnapshotNotifier,
      );

      return controller.groupByTreeTable;
    } else {
      // Nothing collected yet (snapshots/analyses) - return an empty area.
      return const SizedBox();
    }
  }
}

class _LibraryRefColumn extends TreeColumnData<Reference> {
  _LibraryRefColumn() : super('Library or Class');

  @override
  dynamic getValue(Reference dataObject) {
    // Should never be empty when we're displaying in table.
    assert(!dataObject.isEmptyReference);

    String value;
    if (dataObject.isLibrary) {
      value = (dataObject as LibraryReference).name;
      final splitValues = value.split('/');

      value = splitValues.length > 1
          ? '${splitValues[0]}/${splitValues[1]}'
          : splitValues[0];
    } else {
      value = dataObject.name;
    }
    return value;
  }

  @override
  String getDisplayValue(Reference dataObject) => getValue(dataObject);

  @override
  bool get supportsSorting => true;

  @override
  String getTooltip(Reference dataObject) {
    return dataObject.name;
  }

  @override
  double get fixedWidthPx => 250.0;
}

class _ClassOrInstanceCountColumn extends ColumnData<Reference> {
  _ClassOrInstanceCountColumn()
      : super(
          'Count',
          alignment: ColumnAlignment.right,
          fixedWidthPx: 75.0,
        );

  @override
  dynamic getValue(Reference dataObject) {
    assert(!dataObject.isEmptyReference);

    // Although the method returns dynamic this implementatation only
    // returns int.

    if (dataObject.name == MemoryController.libraryRootNode ||
        dataObject.name == MemoryController.classRootNode) return 0;

    var count = 0;

    if (dataObject.isExternal) {
      count = dataObject.children.length;
    } else if (dataObject.isAnalysis && dataObject is AnalysisReference) {
      final AnalysisReference analysisReference = dataObject;
      count = analysisReference.countNote;
    } else if (dataObject.isSnapshot && dataObject is SnapshotReference) {
      final SnapshotReference snapshotRef = dataObject;
      for (final child in snapshotRef.children) {
        count += _computeCount(child);
      }
    } else {
      count = _computeCount(dataObject);
    }

    return count;
  }

  /// Return a count based on the Reference type e.g., library, filtered,
  /// class, externals, etc.  Only compute once, store in the Reference.
  int _computeCount(Reference ref) {
    // Only compute the children counts once then store in the Reference.
    if (ref.hasCount) return ref.count;

    var count = 0;

    if (ref.isClass) {
      final ClassReference classRef = ref;
      count = _computeClassInstances(classRef.actualClass);
    } else if (ref.isLibrary) {
      // Return number of classes.
      final LibraryReference libraryReference = ref;
      for (final heapClass in libraryReference.actualClasses) {
        count += _computeClassInstances(heapClass);
      }
    } else if (ref.isFiltered) {
      final FilteredReference filteredRef = ref;
      for (final LibraryReference child in filteredRef.children) {
        for (final heapClass in child.actualClasses) {
          count += _computeClassInstances(heapClass);
        }
      }
    } else if (ref.isExternals) {
      for (ExternalReference externalRef in ref.children) {
        count += externalRef.children.length;
      }
    } else if (ref.isExternal) {
      final ExternalReference externalRef = ref;
      count = externalRef.children.length;
    }

    // Only compute once.
    ref.count = count;

    return count;
  }

  int _computeClassInstances(HeapGraphClassLive liveClass) =>
      liveClass.instancesCount != null ? liveClass.instancesCount : null;

  /// Internal helper for all count values.
  String _displayCount(int count) => count == null ? '--' : '$count';

  @override
  String getDisplayValue(Reference dataObject) =>
      _displayCount(getValue(dataObject));

  @override
  bool get supportsSorting => true;

  @override
  int compare(Reference a, Reference b) {
    // Analysis is always before.
    final Comparable valueA = a.isAnalysis ? 0 : getValue(a);
    final Comparable valueB = b.isAnalysis ? 0 : getValue(b);
    return valueA.compareTo(valueB);
  }
}

class _ShallowSizeColumn extends ColumnData<Reference> {
  _ShallowSizeColumn()
      : super(
          'Shallow',
          alignment: ColumnAlignment.right,
          fixedWidthPx: 100.0,
        );

  int sizeAllVisibleLibraries(List<Reference> references) {
    var sum = 0;
    for (final ref in references) {
      if (ref.isLibrary) {
        final libraryReference = ref as LibraryReference;
        for (final actualClass in libraryReference.actualClasses) {
          sum += actualClass.instancesTotalShallowSizes;
        }
      }
    }
    return sum;
  }

  @override
  dynamic getValue(Reference dataObject) {
    // Should never be empty when we're displaying in table.
    assert(!dataObject.isEmptyReference);

    if (dataObject.name == MemoryController.libraryRootNode ||
        dataObject.name == MemoryController.classRootNode) {
      final snapshot = dataObject.controller.getSnapshot(dataObject);
      final snapshotGraph = snapshot.snapshotGraph;
      return snapshotGraph.shallowSize + snapshotGraph.externalSize;
    }

    if (dataObject.isAnalysis && dataObject is AnalysisReference) {
      final AnalysisReference analysisReference = dataObject;
      final size = analysisReference.sizeNote;
      return size ?? '';
    } else if (dataObject.isSnapshot && dataObject is SnapshotReference) {
      var sum = 0;
      final SnapshotReference snapshotRef = dataObject;
      for (final childRef in snapshotRef.children) {
        sum += _sumShallowSize(childRef);
      }
      return sum;
    } else {
      final sum = _sumShallowSize(dataObject);
      return sum ?? '';
    }
  }

  dynamic _sumShallowSize(Reference ref) {
    if (ref.isLibrary) {
      // Return number of classes.
      final LibraryReference libraryReference = ref;
      var sum = 0;
      for (final actualClass in libraryReference.actualClasses) {
        sum += actualClass.instancesTotalShallowSizes;
      }
      return sum;
    } else if (ref.isClass) {
      final classReference = ref as ClassReference;
      return classReference.actualClass.instancesTotalShallowSizes;
    } else if (ref.isObject) {
      // Return number of instances.
      final objectReference = ref as ObjectReference;

      var size = objectReference.instance.origin.shallowSize;

      // If it's an external object then return the externalSize too.
      if (ref is ExternalObjectReference) {
        final ExternalObjectReference externalRef = ref;
        size += externalRef.externalSize;
      }

      return size;
    } else if (ref.isFiltered) {
      final snapshot = ref.controller.getSnapshot(ref);
      final sum = sizeAllVisibleLibraries(snapshot?.libraryRoot?.children);
      final snapshotGraph = snapshot.snapshotGraph;
      return snapshotGraph.shallowSize - sum;
    } else if (ref.isExternals) {
      final snapshot = ref.controller.getSnapshot(ref);
      return snapshot.snapshotGraph.externalSize;
    } else if (ref.isExternal) {
      return (ref as ExternalReference).sumExternalSizes;
    }

    return null;
  }

  @override
  String getDisplayValue(Reference dataObject) {
    final value = getValue(dataObject);

    // TODO(terry): Add percent to display too.
/*
    final total = dataObject.controller.snapshots.last.snapshotGraph.capacity;
    final percentage = (value / total) * 100;
    final displayPercentage = percentage < .050 ? '<<1%'
        : '${NumberFormat.compact().format(percentage)}%';
    print('$displayPercentage [${NumberFormat.compact().format(percentage)}%]');
*/
    if ((dataObject.isAnalysis ||
            dataObject.isAllocations ||
            dataObject.isAllocation) &&
        value is! int) return '';

    return NumberFormat.compact().format(value);
  }

  @override
  bool get supportsSorting => true;

  @override
  int compare(Reference a, Reference b) {
    // Analysis is always before.
    final Comparable valueA = a.isAnalysis ? 0 : getValue(a);
    final Comparable valueB = b.isAnalysis ? 0 : getValue(b);
    return valueA.compareTo(valueB);
  }
}

class _RetainedSizeColumn extends ColumnData<Reference> {
  _RetainedSizeColumn()
      : super(
          'Retained',
          alignment: ColumnAlignment.right,
          fixedWidthPx: 100.0,
        );

  @override
  dynamic getValue(Reference dataObject) {
    // Should never be empty when we're displaying in table.
    assert(!dataObject.isEmptyReference);

    if (dataObject.name == MemoryController.libraryRootNode ||
        dataObject.name == MemoryController.classRootNode) return '';

    if (dataObject.isLibrary) {
      // Return number of classes.
      final libraryReference = dataObject as LibraryReference;
      var sum = 0;
      for (final actualClass in libraryReference.actualClasses) {
        sum += actualClass.instancesTotalShallowSizes;
      }
      return sum;
    } else if (dataObject.isClass) {
      final classReference = dataObject as ClassReference;
      return classReference.actualClass.instancesTotalShallowSizes;
    } else if (dataObject.isObject) {
      // Return number of instances.
      final objectReference = dataObject as ObjectReference;
      return objectReference.instance.origin.shallowSize;
    } else if (dataObject.isExternals) {
      return dataObject.controller.lastSnapshot.snapshotGraph.externalSize;
    } else if (dataObject.isExternal) {
      return (dataObject as ExternalReference)
          .liveExternal
          .externalProperty
          .externalSize;
    }

    return '';
  }

  @override
  String getDisplayValue(Reference dataObject) {
    final value = getValue(dataObject);
    return '$value';
  }

  @override
  bool get supportsSorting => true;

  @override
  int compare(Reference a, Reference b) {
    // Analysis is always before.
    final Comparable valueA = a.isAnalysis ? 0 : getValue(a);
    final Comparable valueB = b.isAnalysis ? 0 : getValue(b);
    return valueA.compareTo(valueB);
  }
}
