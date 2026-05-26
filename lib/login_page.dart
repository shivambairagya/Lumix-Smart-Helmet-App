import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'register_page.dart';
import 'home_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController otpController   = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool isLoading      = false;
  bool otpSent        = false;
  String verificationId = "";

  @override
  void dispose() {
    phoneController.dispose();
    otpController.dispose();
    super.dispose();
  }

  // ─── SEND OTP ─────────────────────────────────────────
  Future<void> _sendOtp() async {
    if (phoneController.text.isEmpty) {
      _showSnackBar("Please enter your phone number");
      return;
    }

    setState(() => isLoading = true);

    String phone = phoneController.text.trim();
    if (!phone.startsWith('+')) {
      phone = '+91$phone'; // Add India code if not present
    }

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          await _auth.signInWithCredential(credential);
          _onLoginSuccess();
        },
        verificationFailed: (FirebaseAuthException e) {
          setState(() => isLoading = false);
          _showSnackBar("Failed: ${e.message}");
        },
        codeSent: (String vId, int? resendToken) {
          setState(() {
            isLoading      = false;
            otpSent        = true;
            verificationId = vId;
          });
          _showSnackBar("OTP sent successfully!");
        },
        codeAutoRetrievalTimeout: (String vId) {
          verificationId = vId;
        },
      );
    } catch (e) {
      setState(() => isLoading = false);
      _showSnackBar("Error: ${e.toString()}");
    }
  }

  // ─── VERIFY OTP ───────────────────────────────────────
  Future<void> _verifyOtp() async {
    if (otpController.text.isEmpty) {
      _showSnackBar("Please enter OTP");
      return;
    }

    setState(() => isLoading = true);

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode:        otpController.text.trim(),
      );
      await _auth.signInWithCredential(credential);
      _onLoginSuccess();
    } catch (e) {
      setState(() => isLoading = false);
      _showSnackBar("Invalid OTP. Please try again.");
    }
  }

  // ─── ON LOGIN SUCCESS ─────────────────────────────────
  Future<void> _onLoginSuccess() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', true);
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),

              // Header
              Center(
                child: Icon(Icons.sports_motorsports,
                    size: 80, color: Colors.blue[400]),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text(
                  "Smart Helmet",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  "Login to continue",
                  style: TextStyle(color: Colors.grey[400], fontSize: 16),
                ),
              ),
              const SizedBox(height: 48),

              // Phone number field
              Text("Phone Number",
                  style: TextStyle(color: Colors.grey[400], fontSize: 14)),
              const SizedBox(height: 8),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                enabled: !otpSent,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  prefixText: "+91 ",
                  prefixStyle: const TextStyle(color: Colors.blue),
                  hintText: "Enter phone number",
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  filled: true,
                  fillColor: Colors.grey[900],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.blue),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // OTP field
              if (otpSent) ...[
                Text("Enter OTP",
                    style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                const SizedBox(height: 8),
                TextField(
                  controller: otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      letterSpacing: 8),
                  decoration: InputDecoration(
                    hintText: "------",
                    hintStyle: TextStyle(color: Colors.grey[600]),
                    filled: true,
                    fillColor: Colors.grey[900],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.blue),
                    ),
                    counterText: "",
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    setState(() => otpSent = false);
                    otpController.clear();
                  },
                  child: const Text("Change number?",
                      style: TextStyle(color: Colors.blue)),
                ),
              ],

              const SizedBox(height: 24),

              // Send OTP / Verify button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: isLoading
                      ? null
                      : (otpSent ? _verifyOtp : _sendOtp),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text(
                    otpSent ? "Verify OTP" : "Send OTP",
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Register link
              Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const RegisterPage()),
                    );
                  },
                  child: RichText(
                    text: const TextSpan(
                      text: "Don't have an account? ",
                      style: TextStyle(color: Colors.grey),
                      children: [
                        TextSpan(
                          text: "Register",
                          style: TextStyle(
                              color: Colors.blue,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

