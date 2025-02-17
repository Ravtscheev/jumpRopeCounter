import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_earable/widgets/earable_not_connected_warning.dart';
import 'package:open_earable_flutter/src/open_earable_flutter.dart';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Result of a jump rope session.
/// Contains the number of jumps, duration of the session and average jump height.
class JumpRecordResult {
  final String date;
  final int jumps;
  final Duration duration;
  final double avgJumpHeight;

  /// Constructor for JumpRecordResult.
  JumpRecordResult(
      {required this.jumps,
      required this.duration,
      required this.avgJumpHeight})
      : date = DateFormat('dd. MMMM yyyy HH:mm').format(DateTime.now());
}

/// JumpRopeCounter widget.
class JumpRopeCounter extends StatefulWidget {
  /// Instance of OpenEarable device.
  final OpenEarable _openEarable;

  /// Constructor for JumpRopeCounter widget.
  JumpRopeCounter(this._openEarable);

  _JumpRopeCounterState createState() => _JumpRopeCounterState(_openEarable);
}

/// The state of the JumpRopeCounter widget.
/// Contains the UI and logic for the JumpRopeCounter widget.
class _JumpRopeCounterState extends State<JumpRopeCounter>
    with SingleTickerProviderStateMixin {
  /// Instance of OpenEarable device.
  final OpenEarable _openEarable;

  /// Subscription to the IMU sensor.
  StreamSubscription? _imuSubscription;

  /// Jump detection.
  bool _detectedJump = false;

  /// Sampling rate for the accelerometer.
  double _samplingRate = 10.0;

  /// Time slice for calculating velocity and height.
  /// Calculated from sampling rate.
  double _timeSlice = 0.0;

  /// Number of jumps.
  int _jumps = 0;

  /// Number of counted jumps.
  /// Used for calculating the average jump height.
  int _countedJumps = 0;

  /// Z-axis acceleration.
  double _accZ = 0.0;

  /// Average jump height.
  double _avgJumpHeight = 0.0;

  /// Gravitational acceleration.
  final double _gravity = 9.81;

  /// Timer for recording duration.
  Timer? _timer;

  /// Recording state.
  bool _recording = false;

  /// Duration of the recording.
  Duration _duration = Duration();

  /// Maximum number of saved recordings.
  int _maxSavedItems = 50;

  /// List of past recordings.
  late List<JumpRecordResult> _recordings = [];

  /// Tab controller for the two tabs.
  late TabController _tabController;

  /// Amount of tabs.
  late int _tabAmount = 2;

  /// Average current height.
  double _height = 0.0;

  /// The current velocity.
  double _velocity = 0.0;

  /// Variable for the highest jump.
  double _highestJump = 0.0;

  /// Constructor for _JumpRopeCounterState.
  _JumpRopeCounterState(this._openEarable) {
    _timeSlice = 1 / _samplingRate;
  }

  /// Initializes state and sets up listeners for sensor data.
  @override
  void initState() {
    super.initState();
    loadJumpRecordings();
    _tabController =
        TabController(length: _tabAmount, vsync: this, initialIndex: 0);
    if (_openEarable.bleManager.connected) {
      /// Set sampling rate to maximum.
      _openEarable.sensorManager.writeSensorConfig(_buildSensorConfig());

      /// Setup listeners for sensor data.
      _setupListeners();
    }
  }

  /// Cancels the subscription to the IMU sensor when the widget is disposed.
  @override
  void dispose() {
    super.dispose();
    _imuSubscription?.cancel();
  }

  // Loads the past recordings from shared preferences.
  void loadJumpRecordings() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? recordings = prefs.getStringList('jumpRecordings');
    setState(() {
      _recordings = recordings
              ?.map((e) => JumpRecordResult(
                  jumps: int.parse(e.split(',')[0]),
                  duration: Duration(seconds: int.parse(e.split(',')[1])),
                  avgJumpHeight: double.parse(e.split(',')[2])))
              .toList() ??
          [];
    });
  }

  /// Starts the timer.
  void _startTimer() {
    _timer = Timer.periodic(Duration(seconds: 1), (timer) {
      setState(() {
        _duration = _duration + Duration(seconds: 1);
      });
    });
  }

  /// Stops the timer.
  void _stopTimer() {
    if (_timer != null) {
      _timer!.cancel();
      _duration = Duration();
    }
  }

  /// Starts or stops the recording.
  void startStopRecording() {
    if (_recording) {
      setState(() {
        _recording = false;
      });
      _saveResult();
      _stopTimer();
      _resetCounter();
    } else {
      setState(() {
        _recording = true;
        _startTimer();
        _setupListeners();
      });
    }
  }

  /// Resets all counters to 0.
  void _resetCounter() {
    _jumps = 0;
    _countedJumps = 0;
    _avgJumpHeight = 0.0;
    _height = 0.0;
    _velocity = 0.0;
    _highestJump = 0.0;
  }

  /// Saves the result of the recording.
  void _saveResult() {
    if (_recordings.length >= _maxSavedItems) {
      _recordings.removeAt(0);
    }
    _recordings.add(JumpRecordResult(
        jumps: _jumps, duration: _duration, avgJumpHeight: _avgJumpHeight));

    /// Save the recordings to shared preferences.
    saveJumpRecordings();
  }

  ///  Saves the recordings to shared preferences.
  void saveJumpRecordings() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    prefs.setStringList(
        'jumpRecordings',
        _recordings
            .map((e) => '${e.jumps},${e.duration.inSeconds},${e.avgJumpHeight}')
            .toList());
  }

  /// Formats the duration to a string.
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  /// Builds the sensor config.
  OpenEarableSensorConfig _buildSensorConfig() {
    return OpenEarableSensorConfig(
      sensorId: 0,
      samplingRate: _samplingRate,
      latency: 0,
    );
  }

  /// Sets up listeners for sensor data.
  _setupListeners() {
    _imuSubscription =
        _openEarable.sensorManager.subscribeToSensorData(0).listen((data) {
      /// If the recording is stopped, stop processing sensor data.
      if (!_recording) {
        return;
      }
      _processSensorData(data);
    });
  }

  /// Processes the sensor data.
  void _processSensorData(Map<String, dynamic> data) {
    _accZ = data["ACC"]["Z"];
    double currentAcc = _accZ - _gravity;

    _updateJumps(currentAcc);
    _updateAvgJumpHeight(currentAcc);
  }

  /// Updates the number of jumps.
  Future<void> _updateJumps(double currentAcc) async {
    if (currentAcc > 7.5 && !_detectedJump) {
      setState(() {
        _jumps++;
      });
      _detectedJump = true;
    } else if (currentAcc < 0) {
      _detectedJump = false;
    }
  }

  /// Updates the average jump height.
  Future<void> _updateAvgJumpHeight(double currentAcceleration) async {
    /// Integrate acceleration to get velocity and height
    _velocity += currentAcceleration * _timeSlice;
    _height += _velocity * _timeSlice;

    /// If the current height is higher than the highest jump, update the highest jump.
    if (_height > _highestJump) {
      _highestJump = _height;
    }

    /// If the number of counted jumps is smaller than the number of jumps, update the average jump height.
    if (_jumps > _countedJumps) {
      setState(() {
        _avgJumpHeight = (_avgJumpHeight * _countedJumps + _highestJump) /
            (_countedJumps + 1);
        _highestJump = 0.0; // Use the assignment operator to reset _highestJump
        _countedJumps++;
        _velocity = 0.0;
        _height = 0.0;
      });
    }
  }

  /// Builds the UI for the JumpRopeCounter widget.
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabAmount,
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.background,
        appBar: AppBar(
          title: Text('Jump Rope Counter'),
          bottom: TabBar(
            controller: _tabController,
            indicator: BoxDecoration(
                borderRadius: BorderRadius.circular(8), // Creates border
                color: Colors.greenAccent),
            tabs: [
              Tab(text: "Record"),
              Tab(text: "Jump Activity"),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            /// If the earable is not connected, show a warning. Otherwise show the jump counter.
            _openEarable.bleManager.connected
                ? _ropeCounterWidget()
                : EarableNotConnectedWarning(),
            _ropeSkipHistoryWidget(),
          ],
        ),
      ),
    );
  }

  /// Builds the UI for the jump counter.
  Widget _ropeCounterWidget() {
    return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.start, children: [
      Column(children: [
        SizedBox(height: 32),
        Text(
          "Jumps",
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 64),
          child: Text(
            "$_jumps",
            style: TextStyle(
              fontFamily: 'Digital',
              // This is a common monospaced font
              fontSize: 100,
              fontWeight: FontWeight.normal,
            ),
          ),
        ),
      ]),
      Padding(
        padding: EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Column(
            children: [
              Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 32, 0),
                  child: Text("Time")),
              Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 32, 0),
                child: Text(
                  _formatDuration(_duration),
                  style: TextStyle(
                    fontFamily: 'Digital',
                    // This is a common monospaced font
                    fontSize: 60,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
          Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(32, 0, 16, 0),
                child: Text("Avg. Height"),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(32, 0, 16, 0),
                child: Text(
                  _avgJumpHeight.toStringAsFixed(2),
                  style: TextStyle(
                    fontFamily: 'Digital',
                    // This is a common monospaced font
                    fontSize: 60,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
      Expanded(
          child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(32, 0, 32, 64),
          child: ElevatedButton(
            onPressed: startStopRecording,
            style: ElevatedButton.styleFrom(
              fixedSize: Size(250, 70),
              backgroundColor: _recording
                  ? Color(0xfff27777)
                  : Theme.of(context).colorScheme.secondary,
              foregroundColor: Colors.black,
            ),
            child: Text(
              _recording ? "Stop Recording" : "Start Recording",
              style: TextStyle(fontSize: 20),
            ),
          ),
        ),
      ))
    ]));
  }

  /// Builds the UI for the jump rope history.
  Widget _ropeSkipHistoryWidget() {
    return Center(
      child: Column(
        children: [
          SizedBox(height: 16),
          Center(
            child: Text(
              "Your past $_maxSavedItems sessions are saved here.",
              style: TextStyle(
                fontSize: 20,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          SizedBox(height: 16),
          Divider(
            thickness: 2,
          ),
          Expanded(
            child: _recordings.isEmpty
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.info,
                              size: 48,
                              color: Colors.yellow,
                            ),
                            SizedBox(height: 16),
                            Center(
                              child: Text(
                                "No Workouts Found.",
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    itemCount: _recordings.length,
                    physics: BouncingScrollPhysics(),
                    itemBuilder: (context, index) {
                      int _reverseIndex = _recordings.length - index - 1;
                      return _listItem(_reverseIndex);
                    },
                    separatorBuilder: (context, index) {
                      return Divider(
                        thickness: 2,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Builds a list item for the jump rope history.
  /// The list item is a dismissible widget.
  Widget _listItem(index) {
    return Dismissible(
      key: UniqueKey(),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        child: Align(
          child: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Icon(Icons.delete),
          ),
          alignment: Alignment.centerRight,
        ),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          bool delete = true;
          final snackbarController = ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted Entry'),
              duration: Duration(milliseconds: 2000),
              action: SnackBarAction(
                  label: 'Undo', onPressed: () => delete = false),
            ),
          );
          await snackbarController.closed;
          return delete;
        }
        return true;
      },
      onDismissed: (direction) {
        setState(() {
          _recordings.removeAt(index);
          saveJumpRecordings();
        });
      },
      child: ListTile(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.fromLTRB(0, 0, 0, 20),
                child: Text(
                  _recordings[index].date,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  children: [
                    Text(
                      _recordings[index].jumps.toString(),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      "jump count",
                      maxLines: 1,
                    ),
                  ],
                ),
                Column(
                  children: [
                    Text(
                      _recordings[index].duration.toString().substring(2, 7),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      "jump time",
                      maxLines: 1,
                    ),
                  ],
                ),
                Column(
                  children: [
                    Text(
                      _recordings[index].avgJumpHeight.toStringAsFixed(2),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      "avg. height",
                      maxLines: 1,
                    ),
                  ],
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}
