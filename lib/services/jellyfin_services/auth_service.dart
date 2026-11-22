import 'dart:async' show TimeoutException, unawaited;

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_sign_in/google_sign_in.dart';
import '../auth/auth_bootstrap.dart';
import '../auth/auth_lockout.dart';
import '../auth/auth_validators.dart';
import '../sync/cloud_sync_service.dart';
import 'storage_service.dart';
import 'jellyfin_client.dart';
import '../account_store.dart';
import '../profile_avatar_service.dart';
import '../profile_name_service.dart';
import '../../utils/server_url_utils.dart';
import '../../virtual/virtual_adapter.dart';
import '../../virtual/virtual_catalog.dart';

/// Distinguishes *why* an auth attempt failed, so the UI can show an
/// accurate message instead of always assuming a bad password.
enum AuthErrorType {
  none,
  unreachable,        // couldn't connect at all (offline, no route)
  timeout,            // connected (or tried to) but it took too long
  invalidCredentials, // wrong email/password (deliberately not more specific)
  serverError,        // server responded with something unexpected
  unknown,
  invalidInput,       // failed local validation (bad email, empty password...)
  weakPassword,
  emailInUse,
  emailNotVerified,   // account exists but its email isn't verified yet
  verificationSent,   // not an error: account created, verification pending
  rateLimited,        // too many attempts (local lockout or server throttle)
  accountDisabled,
  cancelled,          // person dismissed the Google chooser
  serviceUnavailable, // Firebase isn't configured / failed to start
}

class AuthResult {
  final bool success;
  final AuthErrorType errorType;
  final String message;

  const AuthResult._(this.success, this.errorType, this.message);

  /// [message] is optional friendly text (e.g. "reset email sent").
  factory AuthResult.success([String message = ""]) =>
      AuthResult._(true, AuthErrorType.none, message);

  factory AuthResult.failure(AuthErrorType type, String message) =>
      AuthResult._(false, type, message);

  /// Account created but not usable until the email is verified. Shown as
  /// information, not as an error.
  factory AuthResult.pending(String message) =>
      AuthResult._(false, AuthErrorType.verificationSent, message);

  bool get isPending => errorType == AuthErrorType.verificationSent;
}

class AuthService {
  /// Checks that [serverUrl] points to a reachable Jellyfin server,
  /// without authenticating any user. Hits the unauthenticated
  /// `/System/Info/Public` endpoint, which every Jellyfin server exposes
  /// regardless of login state - a 200 there means "this is a real,
  /// reachable Jellyfin server", independent of whether any particular
  /// username/password will work.
  ///
  /// This is what the server-connection screen should call: server
  /// reachability is a property of the URL, not of a login attempt, so
  /// it shouldn't only surface as a side effect of trying to sign in.
  static Future<AuthResult> checkServer(String serverUrl) async {
    final normalizedUrl = ServerUrlUtils.normalize(serverUrl);

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ));

      final response = await dio.get(
        "$normalizedUrl/System/Info/Public",
        options: Options(validateStatus: (_) => true),
      );

      debugPrint("======================================");
      debugPrint("SERVER CHECK");
      debugPrint("Server: $normalizedUrl");
      debugPrint("Status: ${response.statusCode}");
      debugPrint("Response:");
      debugPrint(response.data?.toString());
      debugPrint("======================================");

      final status = response.statusCode ?? 0;

      if (status != 200) {
        return AuthResult.failure(
          AuthErrorType.serverError,
          "Server returned an unexpected response (HTTP $status). "
              "Double-check the server address is correct.",
        );
      }

      // A 200 from a non-Jellyfin server (e.g. a router login page, or a
      // generic web server) could still slip through, so make sure the
      // body actually looks like Jellyfin's public info payload.
      final data = response.data;
      final looksLikeJellyfin = data is Map && data.containsKey("ProductName");

      if (!looksLikeJellyfin) {
        return AuthResult.failure(
          AuthErrorType.serverError,
          "That address responded, but doesn't look like a Jellyfin server. "
              "Double-check the address and port.",
        );
      }

      return AuthResult.success();
    } on DioException catch (e) {
      debugPrint("======================================");
      debugPrint("SERVER CHECK DIO EXCEPTION");
      debugPrint("Type: ${e.type}");
      debugPrint("Error: ${e.error}");
      debugPrint("Message: ${e.message}");
      debugPrint("======================================");

      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
          return AuthResult.failure(
            AuthErrorType.timeout,
            "Connection to the server timed out. "
                "It may be unreachable from this network.",
          );
        case DioExceptionType.connectionError:
        case DioExceptionType.badCertificate:
          return AuthResult.failure(
            AuthErrorType.unreachable,
            _unreachableMessage(normalizedUrl),
          );
        case DioExceptionType.cancel:
          return AuthResult.failure(
            AuthErrorType.unknown,
            "Server check was cancelled.",
          );
        case DioExceptionType.badResponse:
          return AuthResult.failure(
            AuthErrorType.serverError,
            "Server returned an unexpected response. "
                "Double-check the server address is correct.",
          );
        case DioExceptionType.unknown:
          return AuthResult.failure(
            AuthErrorType.unreachable,
            _unreachableMessage(normalizedUrl),
          );
        default:
          return AuthResult.failure(
            AuthErrorType.unknown,
            "Something went wrong connecting to the server.",
          );
      }
    } catch (e, stackTrace) {
      debugPrint("======================================");
      debugPrint("SERVER CHECK UNKNOWN ERROR");
      debugPrint(e.toString());
      debugPrint(stackTrace.toString());
      debugPrint("======================================");
      return AuthResult.failure(
        AuthErrorType.unknown,
        "Something went wrong. Please try again.",
      );
    }
  }

  // ---------------------------------------------------------------------
  // Accounts (Firebase Auth). Email + password with mandatory email
  // verification, and Google sign-in.
  //
  // Local session note: the rest of the app still reads StorageService
  // (token / user id / username). After a real sign-in we mirror a
  // NON-credential marker there so those code paths keep working. The real
  // credential never leaves Firebase's own storage, and the app's "am I
  // signed in?" gate is Firebase's currentUser (see [restoreSession]).
  // ---------------------------------------------------------------------

  static const String _sessionMarker = 'firebase-session';
  static const String _guestMarker = 'guest-session';

  /// Optional override for the Google OAuth *web* client ID
  /// (`--dart-define=GOOGLE_SERVER_CLIENT_ID=...`). Normally not needed:
  /// on Android it is picked up from google-services.json.
  static const String _googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  static const Duration _resetCooldown = Duration(seconds: 60);
  static const Duration _resendCooldown = Duration(seconds: 60);

  static bool _googleReady = false;

  static fb.FirebaseAuth? get _auth =>
      AuthBootstrap.ready ? fb.FirebaseAuth.instance : null;

  static AuthResult _unavailable() => AuthResult.failure(
        AuthErrorType.serviceUnavailable,
        "Sign-in isn't available right now. Please try again later.",
      );

  /// Email of the signed-in account, if any. In guest mode this is a short
  /// description instead, since it is what the profile screen shows under
  /// the name.
  static String? get currentEmail =>
      _auth?.currentUser?.email ??
      (CloudSync.instance.isGuestActive
          ? 'Guest mode - data stays on this device'
          : null);

  /// True while using the app without an account (nothing is synced).
  static bool get isGuest => CloudSync.instance.isGuestActive;

  /// "Continue Without Account": opens the app with all data stored on this
  /// device only. Works even when Firebase is unavailable.
  static Future<void> startGuestSession() async {
    await CloudSync.instance.startGuest();
    // Guest mode keeps its own avatar and name (saved on this device).
    await ProfileAvatarService.instance.setGuest();
    await _establishGuestLocalSession();
  }

  static Future<void> _establishGuestLocalSession() async {
    final name =
        await ProfileNameService.instance.customNameFor(ProfileNameService.guestId) ??
            'Guest';
    await StorageService.saveServerUrl('http://namesis.local');
    await StorageService.saveToken(_guestMarker);
    await StorageService.saveUser(VirtualCatalog.userId, name);
    VirtualSession.username = name;
    await JellyfinClient.init();
  }

  static bool get isSignedIn => _auth?.currentUser != null;

  /// True when the signed-in account has an email+password sign-in method
  /// (so "delete account" needs the password to re-confirm).
  static bool get usesPasswordSignIn =>
      _auth?.currentUser?.providerData
          .any((p) => p.providerId == 'password') ??
      false;

  static bool get usesGoogleSignIn =>
      _auth?.currentUser?.providerData
          .any((p) => p.providerId == 'google.com') ??
      false;

  /// Signs in with email + password. Unverified emails are rejected.
  static Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    final auth = _auth;
    if (auth == null) return _unavailable();

    final cleanEmail = email.trim();
    final emailError = AuthValidators.email(cleanEmail);
    if (emailError != null) {
      return AuthResult.failure(AuthErrorType.invalidInput, emailError);
    }
    if (password.isEmpty) {
      return AuthResult.failure(
          AuthErrorType.invalidInput, 'Enter your password.');
    }

    final locked = await AuthLockout.remaining();
    if (locked > Duration.zero) return _lockedResult(locked);

    try {
      final cred = await auth
          .signInWithEmailAndPassword(email: cleanEmail, password: password)
          .timeout(const Duration(seconds: 20));
      final user = cred.user;
      if (user == null) {
        return AuthResult.failure(
            AuthErrorType.unknown, 'Something went wrong. Please try again.');
      }

      if (!user.emailVerified) {
        // Correct password, so this is not a failed guess - no lockout hit.
        await signOut();
        return AuthResult.failure(
          AuthErrorType.emailNotVerified,
          'Please verify your email first. Check your inbox (and spam) for '
              'the link we sent.',
        );
      }

      await AuthLockout.reset();
      await _establishLocalSession(user);
      return AuthResult.success();
    } on fb.FirebaseAuthException catch (e) {
      return _mapFirebaseError(e, countAsFailedLogin: true);
    } on TimeoutException {
      return AuthResult.failure(AuthErrorType.timeout,
          'The request timed out. Check your connection and try again.');
    } catch (e) {
      debugPrint('[Auth] login error: ${e.runtimeType}');
      return AuthResult.failure(
          AuthErrorType.unknown, 'Something went wrong. Please try again.');
    }
  }

  /// Creates an account and emails a verification link. The user is signed
  /// out again straight away: they can only get in after verifying.
  static Future<AuthResult> signUp({
    required String email,
    required String password,
  }) async {
    final auth = _auth;
    if (auth == null) return _unavailable();

    final cleanEmail = email.trim();
    final emailError = AuthValidators.email(cleanEmail);
    if (emailError != null) {
      return AuthResult.failure(AuthErrorType.invalidInput, emailError);
    }
    final passwordError =
        AuthValidators.newPassword(password, email: cleanEmail);
    if (passwordError != null) {
      return AuthResult.failure(AuthErrorType.weakPassword, passwordError);
    }

    try {
      final cred = await auth
          .createUserWithEmailAndPassword(
              email: cleanEmail, password: password)
          .timeout(const Duration(seconds: 20));
      final user = cred.user;
      if (user == null) {
        return AuthResult.failure(
            AuthErrorType.unknown, 'Something went wrong. Please try again.');
      }

      try {
        await user.sendEmailVerification();
        await AuthCooldown.start('resend_verification', _resendCooldown);
      } on fb.FirebaseAuthException catch (e) {
        debugPrint('[Auth] verification email failed: ${e.code}');
        await signOut();
        return AuthResult.failure(
          AuthErrorType.emailNotVerified,
          'Your account was created, but we couldn\'t send the verification '
              'email. Tap "Resend verification email" to try again.',
        );
      }

      await signOut();
      return AuthResult.pending(
        'Account created. We sent a verification link to $cleanEmail. '
        'Verify your email, then sign in.',
      );
    } on fb.FirebaseAuthException catch (e) {
      return _mapFirebaseError(e);
    } on TimeoutException {
      return AuthResult.failure(AuthErrorType.timeout,
          'The request timed out. Check your connection and try again.');
    } catch (e) {
      debugPrint('[Auth] signUp error: ${e.runtimeType}');
      return AuthResult.failure(
          AuthErrorType.unknown, 'Something went wrong. Please try again.');
    }
  }

  /// Sends the verification email again. Needs the password because the
  /// person is signed out at this point; they are signed out again after.
  static Future<AuthResult> resendVerification({
    required String email,
    required String password,
  }) async {
    final auth = _auth;
    if (auth == null) return _unavailable();

    final cleanEmail = email.trim();
    final emailError = AuthValidators.email(cleanEmail);
    if (emailError != null) {
      return AuthResult.failure(AuthErrorType.invalidInput, emailError);
    }
    if (password.isEmpty) {
      return AuthResult.failure(AuthErrorType.invalidInput,
          'Enter your password above, then tap resend.');
    }

    final wait = await AuthCooldown.remaining('resend_verification');
    if (wait > Duration.zero) {
      return AuthResult.failure(
        AuthErrorType.rateLimited,
        'Please wait ${AuthLockout.describe(wait)} before asking for '
            'another email.',
      );
    }

    final locked = await AuthLockout.remaining();
    if (locked > Duration.zero) return _lockedResult(locked);

    try {
      final cred = await auth
          .signInWithEmailAndPassword(email: cleanEmail, password: password)
          .timeout(const Duration(seconds: 20));
      final user = cred.user;
      if (user == null) {
        return AuthResult.failure(
            AuthErrorType.unknown, 'Something went wrong. Please try again.');
      }
      if (user.emailVerified) {
        await signOut();
        return AuthResult.success(
            'Your email is already verified. You can sign in now.');
      }
      await user.sendEmailVerification();
      await AuthCooldown.start('resend_verification', _resendCooldown);
      await signOut();
      return AuthResult.success(
          'Verification email sent to $cleanEmail. Check your inbox and spam.');
    } on fb.FirebaseAuthException catch (e) {
      await signOut();
      return _mapFirebaseError(e, countAsFailedLogin: true);
    } on TimeoutException {
      return AuthResult.failure(AuthErrorType.timeout,
          'The request timed out. Check your connection and try again.');
    } catch (e) {
      debugPrint('[Auth] resend error: ${e.runtimeType}');
      return AuthResult.failure(
          AuthErrorType.unknown, 'Something went wrong. Please try again.');
    }
  }

  /// Emails a password-reset link. The answer never reveals whether an
  /// account exists for the address.
  static Future<AuthResult> sendPasswordReset(String email) async {
    final auth = _auth;
    if (auth == null) return _unavailable();

    final cleanEmail = email.trim();
    final emailError = AuthValidators.email(cleanEmail);
    if (emailError != null) {
      return AuthResult.failure(AuthErrorType.invalidInput, emailError);
    }

    final wait = await AuthCooldown.remaining('password_reset');
    if (wait > Duration.zero) {
      return AuthResult.failure(
        AuthErrorType.rateLimited,
        'Please wait ${AuthLockout.describe(wait)} before asking for '
            'another reset email.',
      );
    }

    const generic = 'If an account exists for that email, we\'ve sent a '
        'password reset link. Check your inbox and spam.';

    try {
      await auth
          .sendPasswordResetEmail(email: cleanEmail)
          .timeout(const Duration(seconds: 20));
      await AuthCooldown.start('password_reset', _resetCooldown);
      return AuthResult.success(generic);
    } on fb.FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') {
        await AuthCooldown.start('password_reset', _resetCooldown);
        return AuthResult.success(generic);
      }
      return _mapFirebaseError(e);
    } on TimeoutException {
      return AuthResult.failure(AuthErrorType.timeout,
          'The request timed out. Check your connection and try again.');
    } catch (e) {
      debugPrint('[Auth] reset error: ${e.runtimeType}');
      return AuthResult.failure(
          AuthErrorType.unknown, 'Something went wrong. Please try again.');
    }
  }

  static Future<void> _ensureGoogle() async {
    if (_googleReady) return;
    await GoogleSignIn.instance.initialize(
      serverClientId:
          _googleServerClientId.isEmpty ? null : _googleServerClientId,
    );
    _googleReady = true;
  }

  /// Google sign-in (Android Credential Manager) exchanged for a Firebase
  /// session. Google accounts arrive with a verified email.
  static Future<AuthResult> signInWithGoogle() async {
    final auth = _auth;
    if (auth == null) return _unavailable();

    try {
      await _ensureGoogle();
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        return AuthResult.failure(AuthErrorType.unknown,
            'Google didn\'t return a valid sign-in. Please try again.');
      }

      final cred = await auth
          .signInWithCredential(fb.GoogleAuthProvider.credential(idToken: idToken))
          .timeout(const Duration(seconds: 20));
      final user = cred.user;
      if (user == null) {
        return AuthResult.failure(
            AuthErrorType.unknown, 'Something went wrong. Please try again.');
      }

      await _establishLocalSession(user, googlePhoto: account.photoUrl);
      return AuthResult.success();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return AuthResult.failure(AuthErrorType.cancelled, '');
      }
      debugPrint('[Auth] Google sign-in failed: ${e.code.name}');
      return AuthResult.failure(AuthErrorType.unknown,
          'Google sign-in failed. Please try again.');
    } on fb.FirebaseAuthException catch (e) {
      return _mapFirebaseError(e);
    } on TimeoutException {
      return AuthResult.failure(AuthErrorType.timeout,
          'The request timed out. Check your connection and try again.');
    } catch (e) {
      debugPrint('[Auth] Google sign-in error: ${e.runtimeType}');
      return AuthResult.failure(
          AuthErrorType.unknown, 'Google sign-in failed. Please try again.');
    }
  }

  /// Runs at launch. True only when a real Firebase session exists, still
  /// belongs to an enabled account, and (for email accounts) is verified.
  /// Offline launches keep the existing session so downloads stay usable.
  static Future<bool> restoreSession() async {
    final auth = _auth;
    var user = auth?.currentUser;

    // Guest mode survives app restarts (and works without Firebase).
    if (user == null && await CloudSync.instance.resumeGuestIfActive()) {
      await ProfileAvatarService.instance.setGuest();
      final token = await StorageService.getToken();
      if (token == null || token.isEmpty) {
        await _establishGuestLocalSession();
      } else {
        VirtualSession.username = await ProfileNameService.instance
                .customNameFor(ProfileNameService.guestId) ??
            'Guest';
      }
      return true;
    }

    if (auth == null) return false;

    if (user == null) {
      // Leftover marker from an older build / a logout that was interrupted.
      final stale = await StorageService.getToken();
      if (stale != null && stale.isNotEmpty) {
        await StorageService.logoutUser();
      }
      return false;
    }

    try {
      await user.reload().timeout(const Duration(seconds: 5));
    } on fb.FirebaseAuthException catch (e) {
      const dead = {
        'user-disabled',
        'user-not-found',
        'user-token-expired',
        'invalid-user-token',
      };
      if (dead.contains(e.code)) {
        await signOut();
        await StorageService.logoutUser();
        return false;
      }
      // Anything else (offline, slow network): keep the session.
    } catch (_) {
      // Timeout / offline: keep the session.
    }

    user = auth.currentUser;
    if (user == null) return false;
    if (!user.emailVerified) {
      await signOut();
      await StorageService.logoutUser();
      return false;
    }

    final token = await StorageService.getToken();
    if (token == null || token.isEmpty || token == _guestMarker) {
      await _establishLocalSession(user);
    } else {
      await _startSync(user);
      VirtualSession.username = await _resolveName(user);
      await _syncAvatar(user);
    }
    return true;
  }

  /// Ends the Firebase (and Google) session. Callers still clear local
  /// state with StorageService.logoutUser() as before.
  static Future<void> signOut() async {
    // Pushes unsynced changes, then returns the device to guest scope
    // (account data removed from this device, guest data restored).
    // A no-op for the short-lived sign-ins used during sign-up/verification.
    try {
      await CloudSync.instance.endSession();
    } catch (e) {
      debugPrint('[Auth] sync end failed: ${e.runtimeType}');
    }
    // Nobody is signed in any more: stop showing their picture (the choice
    // itself stays saved for their next sign-in).
    unawaited(ProfileAvatarService.instance.clearCurrent());
    if (!AuthBootstrap.ready) return;
    try {
      await _ensureGoogle();
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('[Auth] Google sign-out skipped: ${e.runtimeType}');
    }
    try {
      await fb.FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('[Auth] sign-out failed: ${e.runtimeType}');
    }
  }

  /// Permanently deletes the signed-in account. Re-confirms identity first
  /// (password for email accounts, a fresh Google prompt for Google ones),
  /// as Firebase requires for sensitive operations.
  static Future<AuthResult> deleteAccount({String? password}) async {
    final auth = _auth;
    final user = auth?.currentUser;
    if (auth == null || user == null) {
      return AuthResult.failure(
          AuthErrorType.unknown,
          isGuest
              ? 'Guest mode has no account to delete. Your data is stored '
                  'only on this device.'
              : 'You\'re not signed in.');
    }

    try {
      if (usesPasswordSignIn && password != null && password.isNotEmpty) {
        final email = user.email;
        if (email == null) {
          return AuthResult.failure(
              AuthErrorType.unknown, 'Couldn\'t verify your account.');
        }
        await user
            .reauthenticateWithCredential(
              fb.EmailAuthProvider.credential(
                  email: email, password: password),
            )
            .timeout(const Duration(seconds: 20));
      } else if (usesGoogleSignIn) {
        await _ensureGoogle();
        final account = await GoogleSignIn.instance.authenticate();
        final idToken = account.authentication.idToken;
        if (idToken == null || idToken.isEmpty) {
          return AuthResult.failure(AuthErrorType.unknown,
              'Google didn\'t return a valid sign-in. Please try again.');
        }
        await user
            .reauthenticateWithCredential(
                fb.GoogleAuthProvider.credential(idToken: idToken))
            .timeout(const Duration(seconds: 20));
      } else {
        return AuthResult.failure(AuthErrorType.invalidInput,
            'Enter your password to confirm.');
      }

      // Cloud data first (needs the signed-in user); if this fails nothing
      // has been deleted and the account stays intact.
      try {
        await CloudSync.instance.deleteCloudData(user);
      } catch (_) {
        return AuthResult.failure(AuthErrorType.unreachable,
            'Couldn\'t reach the cloud to delete your data. Check your '
            'connection and try again. Account not deleted.');
      }
      try {
        await user.delete().timeout(const Duration(seconds: 20));
      } catch (_) {
        unawaited(CloudSync.instance.startAccount(user));
        rethrow;
      }
      await ProfileAvatarService.instance.forgetCurrent();
      await signOut();
      return AuthResult.success();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return AuthResult.failure(AuthErrorType.cancelled, '');
      }
      return AuthResult.failure(AuthErrorType.unknown,
          'Couldn\'t confirm with Google. Account not deleted.');
    } on fb.FirebaseAuthException catch (e) {
      return _mapFirebaseError(e);
    } on TimeoutException {
      return AuthResult.failure(AuthErrorType.timeout,
          'The request timed out. Account not deleted. Try again.');
    } catch (e) {
      debugPrint('[Auth] delete error: ${e.runtimeType}');
      return AuthResult.failure(AuthErrorType.unknown,
          'Something went wrong. Account not deleted.');
    }
  }

  /// Re-confirms the signed-in account's owner (password for email
  /// accounts, a fresh Google prompt for Google ones) without changing
  /// anything. Used to recover a forgotten Parental Controls PIN.
  static Future<AuthResult> confirmIdentity({String? password}) async {
    final auth = _auth;
    final user = auth?.currentUser;
    if (auth == null || user == null) {
      return AuthResult.failure(
          AuthErrorType.unknown, 'You\'re not signed in.');
    }
    try {
      if (usesPasswordSignIn && password != null && password.isNotEmpty) {
        final email = user.email;
        if (email == null) {
          return AuthResult.failure(
              AuthErrorType.unknown, 'Couldn\'t verify your account.');
        }
        await user
            .reauthenticateWithCredential(
              fb.EmailAuthProvider.credential(
                  email: email, password: password),
            )
            .timeout(const Duration(seconds: 20));
      } else if (usesGoogleSignIn) {
        await _ensureGoogle();
        final account = await GoogleSignIn.instance.authenticate();
        final idToken = account.authentication.idToken;
        if (idToken == null || idToken.isEmpty) {
          return AuthResult.failure(AuthErrorType.unknown,
              'Google didn\'t return a valid sign-in. Please try again.');
        }
        await user
            .reauthenticateWithCredential(
                fb.GoogleAuthProvider.credential(idToken: idToken))
            .timeout(const Duration(seconds: 20));
      } else {
        return AuthResult.failure(AuthErrorType.invalidInput,
            'Enter your password to confirm.');
      }
      return AuthResult.success();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return AuthResult.failure(AuthErrorType.cancelled, '');
      }
      return AuthResult.failure(AuthErrorType.unknown,
          'Couldn\'t confirm with Google. Please try again.');
    } on fb.FirebaseAuthException catch (e) {
      return _mapFirebaseError(e);
    } on TimeoutException {
      return AuthResult.failure(AuthErrorType.timeout,
          'The request timed out. Try again.');
    } catch (e) {
      debugPrint('[Auth] confirm error: ${e.runtimeType}');
      return AuthResult.failure(
          AuthErrorType.unknown, 'Something went wrong. Try again.');
    }
  }

  static String _displayName(fb.User user) {
    final name = user.displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final email = user.email;
    if (email != null && email.contains('@')) return email.split('@').first;
    return 'Guest';
  }

  /// The name to show for [user]: the one they typed on the Edit Profile
  /// page if there is one, otherwise the account's own name.
  static Future<String> _resolveName(fb.User user) async {
    final custom = await ProfileNameService.instance.customNameFor(user.uid);
    return custom ?? _displayName(user);
  }

  /// Never lets a sync problem block sign-in: the app keeps working on
  /// local data and syncs on the next start.
  static Future<void> _startSync(fb.User user) async {
    try {
      await CloudSync.instance.startAccount(user);
    } catch (e) {
      debugPrint('[Auth] sync start failed: ${e.runtimeType}');
    }
  }

  static Future<void> _establishLocalSession(fb.User user,
      {String? googlePhoto}) async {
    final name = await _resolveName(user);
    // Switches this device to the account's data (and pulls it) before
    // anything else touches local data.
    await _startSync(user);
    await _syncAvatar(user, googlePhoto: googlePhoto);
    await StorageService.saveServerUrl('http://namesis.local');
    await StorageService.saveToken(_sessionMarker);
    await StorageService.saveUser(VirtualCatalog.userId, name);
    VirtualSession.username = name;
    await JellyfinClient.init();
    await AccountStore.rememberCurrent();
  }

  /// Tells the profile-picture service who is signed in and whether the
  /// account came from Google (then its photo is shown). Never throws.
  static Future<void> _syncAvatar(fb.User user, {String? googlePhoto}) async {
    try {
      var isGoogle = false;
      String? photo = user.photoURL;
      for (final p in user.providerData) {
        if (p.providerId == 'google.com') {
          isGoogle = true;
          if (photo == null || photo.isEmpty) photo = p.photoURL;
        }
      }
      if (photo == null || photo.isEmpty) photo = googlePhoto;
      await ProfileAvatarService.instance.setUser(
        uid: user.uid,
        isGoogle: isGoogle,
        googlePhotoUrl: photo,
      );
    } catch (e) {
      debugPrint('[Auth] avatar sync skipped: ${e.runtimeType}');
    }
  }

  static AuthResult _lockedResult(Duration left) => AuthResult.failure(
        AuthErrorType.rateLimited,
        'Too many attempts. Try again in ${AuthLockout.describe(left)}.',
      );

  static Future<AuthResult> _mapFirebaseError(
    fb.FirebaseAuthException e, {
    bool countAsFailedLogin = false,
  }) async {
    // The code is safe to log; never log emails, passwords or tokens.
    debugPrint('[Auth] FirebaseAuthException: ${e.code}');

    switch (e.code) {
      case 'invalid-credential':
      case 'invalid-login-credentials':
      case 'wrong-password':
      case 'user-not-found':
        if (countAsFailedLogin) {
          final lock = await AuthLockout.recordFailure();
          if (lock > Duration.zero) {
            return AuthResult.failure(
              AuthErrorType.rateLimited,
              'Incorrect email or password. Too many attempts - try again '
                  'in ${AuthLockout.describe(lock)}.',
            );
          }
        }
        return AuthResult.failure(AuthErrorType.invalidCredentials,
            'Incorrect email or password.');
      case 'too-many-requests':
        if (countAsFailedLogin) await AuthLockout.recordFailure();
        return AuthResult.failure(
          AuthErrorType.rateLimited,
          'Too many attempts. Please wait a few minutes and try again.',
        );
      case 'invalid-email':
        return AuthResult.failure(AuthErrorType.invalidInput,
            'That doesn\'t look like a valid email address.');
      case 'email-already-in-use':
        return AuthResult.failure(
          AuthErrorType.emailInUse,
          'An account with this email already exists. Try signing in, or '
              'use Google if you signed up that way.',
        );
      case 'account-exists-with-different-credential':
      case 'credential-already-in-use':
        return AuthResult.failure(
          AuthErrorType.emailInUse,
          'An account with this email already exists using a different '
              'sign-in method. Sign in the way you first did.',
        );
      case 'weak-password':
        return AuthResult.failure(AuthErrorType.weakPassword,
            'That password is too weak. Pick a longer, harder one.');
      case 'user-disabled':
        return AuthResult.failure(AuthErrorType.accountDisabled,
            'This account has been disabled.');
      case 'requires-recent-login':
        return AuthResult.failure(AuthErrorType.invalidCredentials,
            'Please confirm it\'s you and try again.');
      case 'network-request-failed':
        return AuthResult.failure(AuthErrorType.unreachable,
            'No connection. Check your internet and try again.');
      case 'operation-not-allowed':
        return AuthResult.failure(AuthErrorType.serviceUnavailable,
            'This sign-in method isn\'t switched on yet.');
      default:
        return AuthResult.failure(
            AuthErrorType.unknown, 'Something went wrong. Please try again.');
    }
  }

  /// "Couldn't reach the server" message, with a specific hint when the
  /// address is a localhost/loopback address - since that's a common,
  /// confusing mistake (it means "this device", not "my server").
  static String _unreachableMessage(String normalizedUrl) {
    final host = Uri.tryParse(normalizedUrl)?.host.toLowerCase() ?? "";
    final isLoopback = host == "localhost" ||
        host == "127.0.0.1" ||
        host == "::1" ||
        host == "[::1]";

    if (isLoopback) {
      return "Couldn't reach the server at \"$normalizedUrl\". "
          "\"localhost\" only works if the Jellyfin server is running "
          "on this same device — use your server's local IP or domain instead.";
    }

    return "Couldn't reach the server at \"$normalizedUrl\". "
        "Check that the address is correct and that this device can "
        "reach that network.";
  }
}