// lib/features/prs1/model/prs1_device.dart

class Prs1Device {
  const Prs1Device({
    required this.model,
    required this.serial,
    this.firmware,
  });

  final String model;
  final String serial;
  final String? firmware;
}
