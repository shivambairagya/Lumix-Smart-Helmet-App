import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'home_page.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController nameController          = TextEditingController();
  final TextEditingController phoneController         = TextEditingController();
  final TextEditingController emergencyController     = TextEditingController();
  final TextEditingController otpController           = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool isLoading       = false;
  bool otpSent         = false;
  String verificationId = "";

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    emergencyController.dispose();
    otpController.dispose();
    super.dispose();
  }

  // ─── SEND OTP ─────────────────────────────────────────
  Future<void> _sendOtp() async {
    if (nameController.text.isEmpty) {
      _showSnackBar("Please enter your name");
      return;
    }
    if (phoneController.text.isEmpty) {
      _showSnackBar("Please enter your phone number");
      return;
    }
    if (emergencyController.text.isEmpty) {
      _showSnackBar("Please enter emergency contact");
      return;
    }

    setState(() => isLoading = true);

    String phone = phoneController.text.trim();
    if (!phone.startsWith('+')) {
      phone = '+91$phone';
    }

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          await _auth.signInWithCredential(credential);
          _onRegisterSuccess();
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
      _onRegisterSuccess();
    } catch (e) {
      setState(() => isLoading = false);
      _showSnackBar("Invalid OTP. Please try again.");
    }
  }

  // ─── ON REGISTER SUCCESS ──────────────────────────────
  Future<void> _onRegisterSuccess() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', true);
    await prefs.setString('userName', nameController.text.trim());
    await prefs.setString('userPhone', phoneController.text.trim());
    await prefs.setString('emergencyContact', emergencyController.text.trim());
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
            (route) => false,
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
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text("Register",
            style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),

              // Header
              Center(
                child: Icon(Icons.sports_motorsports,
                    size: 70, color: Colors.blue[400]),
              ),
              const SizedBox(height: 24),

              // Name field
              _buildLabel("Full Name"),
              _buildTextField(
                controller: nameController,
                hint:        "Enter your full name",
                icon:        Icons.person,
                enabled:     !otpSent,
              ),
              const SizedBox(height: 16),

              // Phone field
              _buildLabel("Phone Number"),
              _buildTextField(
                controller:  phoneController,
                hint:        "Enter phone number",
                icon:        Icons.phone,
                keyboard:    TextInputType.phone,
                enabled:     !otpSent,
                prefix:      "+91 ",
              ),
              const SizedBox(height: 16),

              // Emergency contact
              _buildLabel("Emergency Contact Number"),
              _buildTextField(
                controller: emergencyController,
                hint:       "Emergency contact phone",
                icon:       Icons.emergency,
                keyboard:   TextInputType.phone,
                enabled:    !otpSent,
                prefix:     "+91 ",
              ),
              const SizedBox(height: 24),

              // OTP field
              if (otpSent) ...[
                _buildLabel("Enter OTP"),
                TextField(
                  controller:   otpController,
                  keyboardType: TextInputType.number,
                  maxLength:    6,
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
                      borderSide:
                      const BorderSide(color: Colors.blue),
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
                const SizedBox(height: 16),
              ],

              // Button
              SizedBox(
                width:  double.infinity,
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
                      ? const CircularProgressIndicator(
                      color: Colors.white)
                      : Text(
                    otpSent ? "Verify & Register" : "Send OTP",
                    style: const TextStyle(
                        color:      Colors.white,
                        fontSize:   18,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: TextStyle(color: Colors.grey[400], fontSize: 14)),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType keyboard = TextInputType.text,
    bool enabled = true,
    String? prefix,
  }) {
    return TextField(
      controller:   controller,
      keyboardType: keyboard,
      enabled:      enabled,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: Colors.blue),
        prefixText: prefix,
        prefixStyle: const TextStyle(color: Colors.blue),
        hintText:  hint,
        hintStyle: TextStyle(color: Colors.grey[600]),
        filled:    true,
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
    );
  }
}
