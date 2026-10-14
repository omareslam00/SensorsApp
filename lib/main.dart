import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const RicePackingApp());
}

class RicePackingApp extends StatelessWidget {
  const RicePackingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RicePack Smart Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0F766E), // Smart Teal/Slate palette
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
          ),
          color: Colors.white,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  // --- Connection State ---
  String _espIp = '192.168.1.100';
  bool _isConnected = false;
  bool _isSimulationMode = true; // Enabled by default for instant testing
  Timer? _pollingTimer;

  // --- Sensor & Control State ---
  bool _systemRunning = true;
  bool _isTankEmpty = false;
  int _packagesPassed = 124;
  double _currentHumidity = 46.5;

  // --- Adjustable Setpoints ---
  double _riceWeightGrams = 200.0; // Range: 100g to 300g
  double _conveyorSpeed = 60.0; // Range: 0% to 100%
  double _targetHumidity = 55.0; // Adjustable threshold: 20% to 80%

  // --- Animation Controller for Conveyor & Alerts ---
  late final AnimationController _conveyorAnimController;

  @override
  void initState() {
    super.initState();
    _conveyorAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();

    _startDataLoop();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _conveyorAnimController.dispose();
    super.dispose();
  }

  // Updates animation speed based on conveyor slider
  void _updateConveyorAnimation() {
    if (!_systemRunning || _conveyorSpeed <= 0 || _isTankEmpty) {
      _conveyorAnimController.stop();
    } else {
      final int durationMs = (2000 - (_conveyorSpeed * 16)).clamp(250, 2000).toInt();
      _conveyorAnimController.duration = Duration(milliseconds: durationMs);
      if (!_conveyorAnimController.isAnimating) {
        _conveyorAnimController.repeat();
      }
    }
  }

  // Periodic loop for polling ESP32 or running simulated sensors
  void _startDataLoop() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isSimulationMode) {
        _simulateSensorData();
      } else {
        _fetchEspStatus();
      }
    });
  }

  void _simulateSensorData() {
    if (!mounted) return;
    final rng = Random();
    setState(() {
      _isConnected = true;
      // Fluctuate humidity gently towards target
      double drift = (rng.nextDouble() - 0.48) * 0.6;
      _currentHumidity = (_currentHumidity + drift).clamp(25.0, 85.0);

      // Increment package count if running, tank has rice, and conveyor is moving
      if (_systemRunning && !_isTankEmpty && _conveyorSpeed > 10) {
        if (rng.nextDouble() < (_conveyorSpeed / 180.0)) {
          _packagesPassed++;
        }
      }
    });
  }

  Future<void> _fetchEspStatus() async {
    try {
      final uri = Uri.parse('http://$_espIp/status');
      final response = await http.get(uri).timeout(const Duration(milliseconds: 800));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (!mounted) return;
        setState(() {
          _isConnected = true;
          _isTankEmpty = data['tankEmpty'] ?? false;
          _packagesPassed = data['packagesPassed'] ?? _packagesPassed;
          _currentHumidity = (data['currentHumidity'] ?? _currentHumidity).toDouble();
        });
        _updateConveyorAnimation();
      } else {
        if (mounted) setState(() => _isConnected = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isConnected = false);
    }
  }

  Future<void> _sendControlToEsp({bool resetCounter = false}) async {
    _updateConveyorAnimation();
    if (_isSimulationMode) {
      if (resetCounter) {
        setState(() => _packagesPassed = 0);
      }
      return;
    }

    try {
      final uri = Uri.parse('http://$_espIp/control');
      await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'targetWeight': _riceWeightGrams.round(),
              'conveyorSpeed': _conveyorSpeed.round(),
              'targetHumidity': double.parse(_targetHumidity.toStringAsFixed(1)),
              'systemRunning': _systemRunning,
              'resetCounter': resetCounter,
            }),
          )
          .timeout(const Duration(milliseconds: 800));

      if (resetCounter && mounted) {
        setState(() => _packagesPassed = 0);
      }
    } catch (_) {
      if (mounted) setState(() => _isConnected = false);
    }
  }

  void _showWifiConfigDialog() {
    final controller = TextEditingController(text: _espIp);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ESP32 Wi-Fi Configuration'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the local IP address printed on your ESP32 Serial Monitor:',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'ESP32 IP Address',
                hintText: '192.168.1.100',
                prefixIcon: const Icon(Icons.wifi),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                _espIp = controller.text.trim();
                _isSimulationMode = false;
              });
              Navigator.pop(context);
              _fetchEspStatus();
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0F766E).withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.precision_manufacturing, color: Color(0xFF0F766E)),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RicePack Control',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
                ),
                Text(
                  'ESP32 Automated Packaging Line',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // Simulation / Wi-Fi Mode Chip
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: FilterChip(
              label: Text(_isSimulationMode ? 'Sim Mode' : 'ESP32 Live'),
              selected: !_isSimulationMode,
              avatar: Icon(
                _isSimulationMode ? Icons.science : Icons.wifi,
                size: 16,
              ),
              onSelected: (val) {
                setState(() {
                  _isSimulationMode = !val;
                  if (_isSimulationMode) _isConnected = true;
                });
              },
            ),
          ),
          IconButton(
            tooltip: 'ESP32 IP Settings',
            icon: const Icon(Icons.settings_ethernet),
            onPressed: _showWifiConfigDialog,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildTopStatusBanner(),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth > 720;
                      if (isWide) {
                        return Column(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: _buildTankStatusCard()),
                                const SizedBox(width: 16),
                                Expanded(child: _buildPackageCounterCard()),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: _buildWeightSliderCard()),
                                const SizedBox(width: 16),
                                Expanded(child: _buildConveyorSpeedCard()),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _buildHumidityCard(),
                          ],
                        );
                      } else {
                        return Column(
                          children: [
                            _buildTankStatusCard(),
                            const SizedBox(height: 16),
                            _buildPackageCounterCard(),
                            const SizedBox(height: 16),
                            _buildWeightSliderCard(),
                            const SizedBox(height: 16),
                            _buildConveyorSpeedCard(),
                            const SizedBox(height: 16),
                            _buildHumidityCard(),
                          ],
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- 1. Top Connection & Master System Control Banner ---
  Widget _buildTopStatusBanner() {
    final Color statusColor = _isConnected ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: statusColor.withOpacity(0.5),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isSimulationMode
                        ? 'Simulation Active (Virtual Sensors)'
                        : (_isConnected ? 'Connected to ESP32 ($_espIp)' : 'Offline - Searching for $_espIp...'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    _systemRunning && !_isTankEmpty
                        ? 'System Status: Packing Active'
                        : (_isTankEmpty ? 'System Halted: Tank Empty!' : 'System Status: Paused'),
                    style: TextStyle(
                      color: _isTankEmpty ? const Color(0xFFFCA5A5) : Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Master Run',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(width: 8),
              Switch(
                value: _systemRunning,
                activeColor: const Color(0xFF10B981),
                onChanged: (val) {
                  setState(() => _systemRunning = val);
                  _sendControlToEsp();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- 2. Rice Tank Sensor Card ---
  Widget _buildTankStatusCard() {
    final Color stateColor = _isTankEmpty ? const Color(0xFFEF4444) : const Color(0xFF0F766E);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _isTankEmpty ? Icons.warning_amber_rounded : Icons.storage_rounded,
                      color: stateColor,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Rice Hopper Tank',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                if (_isSimulationMode)
                  TextButton.icon(
                    onPressed: () {
                      setState(() => _isTankEmpty = !_isTankEmpty);
                      _updateConveyorAnimation();
                    },
                    icon: const Icon(Icons.swap_vert, size: 16),
                    label: const Text('Toggle Sensor', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                // Animated Visual Tank Graphic
                Container(
                  width: 76,
                  height: 110,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: stateColor.withOpacity(0.4), width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  alignment: Alignment.bottomCenter,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeInOutCubic,
                    width: double.infinity,
                    height: _isTankEmpty ? 10 : 88,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: _isTankEmpty
                            ? [const Color(0xFFFCA5A5), const Color(0xFFEF4444)]
                            : [const Color(0xFF14B8A6), const Color(0xFF0F766E)],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Container(
                          key: ValueKey<bool>(_isTankEmpty),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: stateColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: Text(
                            _isTankEmpty ? 'ALERT: TANK EMPTY' : 'SUFFICIENT LEVEL',
                            style: TextStyle(
                              color: stateColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _isTankEmpty
                            ? 'Optical/Float level sensor triggered! Dosing valve & conveyor paused until hopper is refilled.'
                            : 'Hopper sensor detects grain supply. Automatic dosing valve ready.',
                        style: const TextStyle(fontSize: 13, color: Colors.black54, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- 3. Package Counter Sensor Card ---
  Widget _buildPackageCounterCard() {
    final double totalKgPacked = (_packagesPassed * _riceWeightGrams) / 1000.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.inventory_2_outlined, color: Color(0xFF2563EB)),
                    SizedBox(width: 10),
                    Text(
                      'Packages Passed Sensor',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                OutlinedButton.icon(
                  onPressed: () => _sendControlToEsp(resetCounter: true),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Reset', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: _packagesPassed.toDouble()),
                  duration: const Duration(milliseconds: 400),
                  builder: (context, value, _) {
                    return Text(
                      value.toInt().toString(),
                      style: const TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1E293B),
                        height: 1.0,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 10),
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    'packs',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.black45,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Estimated Output Mass:',
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  Text(
                    '${totalKgPacked.toStringAsFixed(2)} kg',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- 4. Rice Weight Slider Card (100g - 300g) ---
  Widget _buildWeightSliderCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.scale_outlined, color: Color(0xFF0F766E)),
                    SizedBox(width: 10),
                    Text(
                      'Package Weight Setpoint',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F766E).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_riceWeightGrams.round()} g',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFF0F766E),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Adjusts load-cell / dosing gate cut-off between 100g and 300g per bag.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 8,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
              ),
              child: Slider(
                value: _riceWeightGrams,
                min: 100,
                max: 300,
                divisions: 40, // 5g steps
                label: '${_riceWeightGrams.round()} g',
                onChanged: (val) => setState(() => _riceWeightGrams = val),
                onChangeEnd: (_) => _sendControlToEsp(),
              ),
            ),
            // Quick Preset Chips
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [100, 150, 200, 250, 300].map((preset) {
                final isSelected = _riceWeightGrams.round() == preset;
                return ActionChip(
                  label: Text('${preset}g'),
                  backgroundColor: isSelected
                      ? const Color(0xFF0F766E).withOpacity(0.15)
                      : const Color(0xFFF1F5F9),
                  side: BorderSide(
                    color: isSelected ? const Color(0xFF0F766E) : Colors.transparent,
                  ),
                  onPressed: () {
                    setState(() => _riceWeightGrams = preset.toDouble());
                    _sendControlToEsp();
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  // --- 5. Conveyor Speed Slider Card ---
  Widget _buildConveyorSpeedCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.speed_rounded, color: Color(0xFFD97706)),
                    SizedBox(width: 10),
                    Text(
                      'Conveyor Belt Speed',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD97706).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_conveyorSpeed.round()} %',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFFD97706),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Controls PWM duty cycle sent to the conveyor motor driver.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFFD97706),
                thumbColor: const Color(0xFFD97706),
                overlayColor: const Color(0xFFD97706).withOpacity(0.15),
                trackHeight: 8,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
              ),
              child: Slider(
                value: _conveyorSpeed,
                min: 0,
                max: 100,
                divisions: 20,
                label: '${_conveyorSpeed.round()}%',
                onChanged: (val) {
                  setState(() => _conveyorSpeed = val);
                  _updateConveyorAnimation();
                },
                onChangeEnd: (_) => _sendControlToEsp(),
              ),
            ),
            const SizedBox(height: 10),
            // Animated Conveyor Visualizer
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(18),
              ),
              child: AnimatedBuilder(
                animation: _conveyorAnimController,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _ConveyorBeltPainter(
                      progress: _conveyorAnimController.value,
                      isActive: _systemRunning && !_isTankEmpty && _conveyorSpeed > 0,
                    ),
                    child: const SizedBox.expand(),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- 6. Humidity Sensor Monitor & Adjustable Threshold Card ---
  Widget _buildHumidityCard() {
    final bool isHighHumidity = _currentHumidity > _targetHumidity;
    final Color humColor = isHighHumidity ? const Color(0xFFEF4444) : const Color(0xFF0284C7);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.water_drop_outlined, color: humColor),
                    const SizedBox(width: 10),
                    const Text(
                      'Chamber Humidity Monitor & Threshold',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: humColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isHighHumidity ? 'DEHUMIDIFIER ACTIVE' : 'HUMIDITY OPTIMAL',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: humColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 550;
                final sensorDisplay = Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: humColor.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: humColor.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CircularProgressIndicator(
                              value: (_currentHumidity / 100).clamp(0.0, 1.0),
                              strokeWidth: 7,
                              backgroundColor: Colors.black12,
                              color: humColor,
                              strokeCap: StrokeCap.round,
                            ),
                            Center(
                              child: Text(
                                '${_currentHumidity.toStringAsFixed(0)}%',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                  color: humColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Live Sensor Reading',
                              style: TextStyle(fontSize: 12, color: Colors.black54),
                            ),
                            Text(
                              '${_currentHumidity.toStringAsFixed(1)} % RH',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              isHighHumidity
                                  ? 'Exceeds limit (${_targetHumidity.toStringAsFixed(0)}%) — Venting ON'
                                  : 'Safe moisture level for rice storage',
                              style: TextStyle(fontSize: 12, color: humColor),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );

                final thresholdSlider = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Max Allowed Humidity (Adjustable Limit)',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                        Text(
                          '${_targetHumidity.toStringAsFixed(0)} % RH',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: Color(0xFF0284C7),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'ESP32 triggers dehumidifier relay when live humidity exceeds this value.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFF0284C7),
                        thumbColor: const Color(0xFF0284C7),
                        trackHeight: 8,
                      ),
                      child: Slider(
                        value: _targetHumidity,
                        min: 20,
                        max: 80,
                        divisions: 60,
                        label: '${_targetHumidity.round()}%',
                        onChanged: (val) => setState(() => _targetHumidity = val),
                        onChangeEnd: (_) => _sendControlToEsp(),
                      ),
                    ),
                  ],
                );

                if (isWide) {
                  return Row(
                    children: [
                      Expanded(flex: 5, child: sensorDisplay),
                      const SizedBox(width: 24),
                      Expanded(flex: 6, child: thresholdSlider),
                    ],
                  );
                } else {
                  return Column(
                    children: [
                      sensorDisplay,
                      const SizedBox(height: 16),
                      thresholdSlider,
                    ],
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

// Custom Painter for the fluid Conveyor Belt Animation
class _ConveyorBeltPainter extends CustomPainter {
  final double progress;
  final bool isActive;

  _ConveyorBeltPainter({required this.progress, required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isActive ? const Color(0xFFFBBF24) : Colors.white24
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    const double spacing = 28.0;
    final double offset = progress * spacing;

    for (double x = -spacing + offset; x < size.width + spacing; x += spacing) {
      if (x >= 0 && x <= size.width) {
        canvas.drawLine(
          Offset(x, size.height * 0.3),
          Offset(x + 6, size.height * 0.5),
          paint,
        );
        canvas.drawLine(
          Offset(x + 6, size.height * 0.5),
          Offset(x, size.height * 0.7),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ConveyorBeltPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.isActive != isActive;
}