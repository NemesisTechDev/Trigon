/// Client-side input checks for sign-up / sign-in.
///
/// These give instant, friendly feedback and cut obviously bad requests,
/// but they are NOT the security boundary: anyone can call Firebase's REST
/// API directly. The same password rules must also be switched on
/// server-side (Firebase console > Authentication > Settings > Password
/// policy) so they can't be bypassed. See SETUP.md.
class AuthValidators {
  AuthValidators._();

  static const int maxEmailLength = 254;
  static const int minPasswordLength = 8;
  static const int maxPasswordLength = 128;

  static final RegExp _email = RegExp(
    r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$",
  );

  /// A short list of the passwords attackers try first. Length + a letter and
  /// a digit are required below, so only the ones that would pass those
  /// rules need to be listed here.
  static const Set<String> _commonPasswords = {
    'password1',
    'password12',
    'password123',
    'qwerty123',
    'qwerty1234',
    'abc12345',
    'abcd1234',
    'iloveyou1',
    'welcome1',
    'letmein123',
    'admin1234',
    'football1',
    'trustno1',
    'changeme1',
  };

  /// Returns an error message, or null when [value] looks like an email.
  static String? email(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Enter your email address.';
    if (v.length > maxEmailLength || !_email.hasMatch(v)) {
      return 'That doesn\'t look like a valid email address.';
    }
    return null;
  }

  /// Rules for a NEW password (sign-up). Never applied to sign-in, so people
  /// with older/looser passwords can still get in and reset them.
  static String? newPassword(String value, {String? email}) {
    if (value.length < minPasswordLength) {
      return 'Use at least $minPasswordLength characters for your password.';
    }
    if (value.length > maxPasswordLength) {
      return 'That password is too long (max $maxPasswordLength characters).';
    }
    if (!value.contains(RegExp(r'[A-Za-z]')) ||
        !value.contains(RegExp(r'[0-9]'))) {
      return 'Your password needs at least one letter and one number.';
    }
    if (_commonPasswords.contains(value.toLowerCase())) {
      return 'That password is too common. Pick something harder to guess.';
    }
    if (RegExp(r'^(.)\1+$').hasMatch(value)) {
      return 'That password is too easy to guess.';
    }
    final local = (email ?? '').split('@').first.trim().toLowerCase();
    if (local.length >= 4 && value.toLowerCase().contains(local)) {
      return 'Your password shouldn\'t contain your email name.';
    }
    return null;
  }
}
