import 'dart:math';

/// Aadhaar-style unique ID: 12 digits, first digit 2-9, optionally grouped
/// as "XXXX XXXX XXXX" (spaces or dashes).
final RegExp aadhaarRe = RegExp(r'^[2-9]{1}[0-9]{3}[ -]?[0-9]{4}[ -]?[0-9]{4}$');

/// Ration card family ID: 8-16 letters, digits, slashes or dashes.
final RegExp rationRe = RegExp(r'^[A-Za-z0-9/-]{8,16}$');

/// Small default pool of citizen names. Registration pre-fills one of these;
/// the user can overwrite it.
const List<String> kDefaultCitizenNames = [
  'AMARA',
  'BODHI',
  'CHANDRA',
  'DEVI',
  'ELARA',
  'FARID',
  'GAURI',
  'HARSH',
  'ISHAAN',
  'JIVAN',
  'KAILASH',
  'LAKSHMI',
  'MEERA',
  'NAVIN',
  'OMKAR',
  'PRIYA',
];

/// A random name from [kDefaultCitizenNames].
String randomCitizenName([Random? random]) {
  final r = random ?? Random();
  return kDefaultCitizenNames[r.nextInt(kDefaultCitizenNames.length)];
}

/// A valid Aadhaar number: first digit 2-9, grouped by fours with spaces.
String randomAadhaar([Random? random]) {
  final r = random ?? Random();
  final first = r.nextInt(8) + 2; // 2..9
  final rest = List.generate(11, (_) => r.nextInt(10));
  final digits = '$first${rest.join()}';
  return '${digits.substring(0, 4)} ${digits.substring(4, 8)} '
      '${digits.substring(8, 12)}';
}

/// A valid ration card family id: 10 chars from the allowed set.
String randomRationId([Random? random]) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789/-';
  final r = random ?? Random();
  return List.generate(10, (_) => alphabet[r.nextInt(alphabet.length)]).join();
}